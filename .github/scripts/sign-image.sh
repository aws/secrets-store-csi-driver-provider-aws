#!/usr/bin/env bash
#
# The Release workflow's image signing, with cosign. One command per call:
#
#   install-cosign  downloads the pinned cosign release for this runner, checks its sha256, and puts cosign on the
#                   PATH of later steps
#   sign            signs DIGEST in PUBLIC_REPO, keyless: the signing identity is this run's workflow, proven by the
#                   job's GitHub OIDC token. Skips the signing if DIGEST already has a signature from this workflow
#                   (a re-run), and checks the signature after signing
#   verify          checks, with no credentials, that DIGEST in PUBLIC_REPO has a signature from this workflow
#
# Inputs (environment). sign and verify:
#   PUBLIC_REPO          public.ecr.aws/<namespace>/<name>; the production repo exactly when PRACTICE is false
#   PRACTICE             true or false
#   DIGEST               sha256:<64 hex>, the tested image index from the build job
#   GITHUB_WORKFLOW_REF  set by GitHub: <owner>/<repo>/.github/workflows/release.yml@<ref>. A real run must be
#                        release.yml on main
#   RUNNER_TEMP
# sign only:
#   AWS_RETRY_MODE, AWS_MAX_ATTEMPTS   must be set; the AWS CLI does the retries
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN   the publish role's credentials, on the step's env:
#   ACTIONS_ID_TOKEN_REQUEST_URL, ACTIONS_ID_TOKEN_REQUEST_TOKEN  set by GitHub when the job has id-token: write;
#                        cosign uses them to get the OIDC token it signs with
# install-cosign: RUNNER_TEMP, RUNNER_ARCH (X64 or ARM64), GITHUB_PATH
# verify only: AWS_EC2_METADATA_DISABLED must be true, so cosign can't get credentials from the runner itself
# Test-only setting: SIGN_RETRY_SCALE multiplies the pause between signature checks (0 in tests).
#
# What a signature says: this image index was signed by release.yml in aws/secrets-store-csi-driver-provider-aws,
# on the ref above. Only the index is signed (no --recursive): customers pull by tag, and every tag points at the
# index. cosign stores the signature in the same repo as an untagged artifact that refers to DIGEST, and records it
# in Sigstore's public transparency log.
#
# Credentials: cosign's login goes to a temporary DOCKER_CONFIG under RUNNER_TEMP, always removed on exit, never
# ~/.docker. The password reaches cosign on stdin only. verify refuses to start if any AWS credential variable is
# set or AWS_EC2_METADATA_DISABLED isn't true, and reads with an empty DOCKER_CONFIG, so its reads are anonymous,
# the way a customer's are.
#
# Bash 3.2 compatible: `set -e` is off inside functions called from `if`, `||` or `&&`, so every command's exit
# status is tested by hand.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=registry-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"

readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'
readonly PUBLIC_REGISTRY=public.ecr.aws
readonly PUBLIC_REGION=us-east-1 # where ECR Public's auth is
readonly AWS_TIMEOUTS="--cli-read-timeout 30 --cli-connect-timeout 10"
readonly RELEASE_WORKFLOW=aws/secrets-store-csi-driver-provider-aws/.github/workflows/release.yml
readonly WORKFLOW_REF_RE='^aws/secrets-store-csi-driver-provider-aws/\.github/workflows/release\.yml@refs/heads/[A-Za-z0-9._/-]+$'
readonly OIDC_ISSUER=https://token.actions.githubusercontent.com
# The AWS credential, profile and role variables verify refuses to run with.
readonly CREDENTIAL_VARS="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE
AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI"
# The signature check after signing, and verify, read up to 4 times, pausing 10s, 20s, then 30s: the registry can
# take a moment to show a new artifact, and ECR Public limits how fast anonymous reads may come.
readonly VERIFY_ATTEMPTS=4
readonly VERIFY_PAUSE=10
# cosign, pinned by version and by the sha256 of each release binary, from the release's cosign_checksums.txt:
# https://github.com/sigstore/cosign/releases/tag/v3.1.4
# Dependabot cannot update this: bump the version and both checksums together, by hand.
readonly COSIGN_VERSION=v3.1.4
readonly COSIGN_SHA256_AMD64=424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa
readonly COSIGN_SHA256_ARM64=ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2

ok() { echo "✔ $*"; }
fail() {
	echo "✘ $*"
	exit 1
}

work_dir=""
docker_config=""
cleanup() {
	if [[ -n "$work_dir" ]]; then
		rm -rf "$work_dir"
	fi
	if [[ -n "$docker_config" ]]; then
		rm -rf "$docker_config"
	fi
}
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

make_work_dir() {
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/sign-image.XXXXXX") || fail "could not create a temp directory"
}

require() {
	local name
	for name in "$@"; do
		if [[ -z "${!name:-}" ]]; then
			fail "$name is not set"
		fi
	done
}

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

# --- inputs ------------------------------------------------------------------------------------------------------

# Checks PUBLIC_REPO, PRACTICE, DIGEST and RUNNER_TEMP, and sets identity: the certificate identity a signature
# from this run carries, https://github.com/<GITHUB_WORKFLOW_REF>.
require_target() {
	check_target || exit 1
	require DIGEST RUNNER_TEMP GITHUB_WORKFLOW_REF
	if [[ ! "$DIGEST" =~ $DIGEST_RE ]]; then
		fail "DIGEST $(printf '%q' "$DIGEST") is not sha256:<64 lowercase hex>"
	fi
	if [[ "$PRACTICE" == false && "$GITHUB_WORKFLOW_REF" != "$RELEASE_WORKFLOW@refs/heads/main" ]]; then
		fail "a real run must be $RELEASE_WORKFLOW on main, not $(printf '%q' "$GITHUB_WORKFLOW_REF")"
	fi
	if [[ ! "$GITHUB_WORKFLOW_REF" =~ $WORKFLOW_REF_RE ]]; then
		fail "GITHUB_WORKFLOW_REF $(printf '%q' "$GITHUB_WORKFLOW_REF") is not $RELEASE_WORKFLOW on a branch"
	fi
	identity="https://github.com/$GITHUB_WORKFLOW_REF"
}

# Points cosign at a new, private DOCKER_CONFIG under RUNNER_TEMP, holding an empty config.json.
private_docker_config() {
	docker_config=$(mktemp -d "$RUNNER_TEMP/dc.XXXXXX") || fail "could not create a temp DOCKER_CONFIG"
	# With no config.json there, cosign would fall back to podman's saved logins.
	if ! printf '{}\n' >"$docker_config/config.json"; then
		fail "could not write the temp DOCKER_CONFIG"
	fi
	# cosign reads DOCKER_CONFIG from its own environment; without the export its login would go to ~/.docker.
	export DOCKER_CONFIG=$docker_config
}

check_retry_scale() {
	if [[ ! "${SIGN_RETRY_SCALE:-1}" =~ ^[0-9]+$ ]]; then
		fail "SIGN_RETRY_SCALE must be a whole number"
	fi
}

# check_signature : cosign verify of PUBLIC_REPO@DIGEST against this run's identity, output to $work_dir/verify.
# Returns cosign's exit status.
check_signature() {
	local rc=0
	cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$OIDC_ISSUER" \
		"$PUBLIC_REPO@$DIGEST" >"$work_dir/verify" 2>&1 || rc=$?
	return "$rc"
}

# check_signature, up to VERIFY_ATTEMPTS times, pausing longer each time. Returns 1 if every attempt failed, with
# cosign's last output in $work_dir/verify.
check_signature_with_retries() {
	local attempt=1
	while ! check_signature; do
		if ((attempt >= VERIFY_ATTEMPTS)); then
			return 1
		fi
		echo "  no signature from $identity yet (attempt $attempt of $VERIFY_ATTEMPTS); reading again"
		sleep $((VERIFY_PAUSE * attempt * ${SIGN_RETRY_SCALE:-1}))
		attempt=$((attempt + 1))
	done
}

# --- commands ----------------------------------------------------------------------------------------------------

cmd_install_cosign() {
	local asset expected actual url rc=0
	require RUNNER_TEMP RUNNER_ARCH GITHUB_PATH
	case "$RUNNER_ARCH" in
	X64)
		asset=linux-amd64
		expected=$COSIGN_SHA256_AMD64
		;;
	ARM64)
		asset=linux-arm64
		expected=$COSIGN_SHA256_ARM64
		;;
	*) fail "no pinned cosign for RUNNER_ARCH $(printf '%q' "$RUNNER_ARCH") (only X64 and ARM64)" ;;
	esac
	make_work_dir
	url="https://github.com/sigstore/cosign/releases/download/$COSIGN_VERSION/cosign-$asset"
	# --retry covers timeouts and the transient HTTP errors (408, 429, 500, 502, 503, 504); a failed job needs a
	# new approval.
	curl --silent --show-error --fail --location --proto =https --proto-redir =https --retry 3 --max-time 120 \
		--output "$work_dir/cosign" "$url" || rc=$?
	if ((rc != 0)); then
		fail "could not download $url (curl exit $rc)"
	fi
	if ! actual=$(sha256_of "$work_dir/cosign") || [[ -z "$actual" ]]; then
		fail "could not hash the cosign $COSIGN_VERSION download"
	fi
	if [[ "$actual" != "$expected" ]]; then
		fail "the cosign $COSIGN_VERSION download hashes to $actual, not the pinned $expected"
	fi
	if ! mkdir -p "$RUNNER_TEMP/bin" || ! mv "$work_dir/cosign" "$RUNNER_TEMP/bin/cosign" ||
		! chmod 0755 "$RUNNER_TEMP/bin/cosign"; then
		fail "could not install cosign into $RUNNER_TEMP/bin"
	fi
	printf '%s\n' "$RUNNER_TEMP/bin" >>"$GITHUB_PATH"
	ok "installed cosign $COSIGN_VERSION ($asset, sha256 $expected) into $RUNNER_TEMP/bin"
}

cmd_sign() {
	local rc=0
	check_retry_scale
	require_target
	require AWS_RETRY_MODE AWS_MAX_ATTEMPTS ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN
	make_work_dir
	private_docker_config

	# shellcheck disable=SC2086 # AWS_TIMEOUTS is split into its flags on purpose
	aws ecr-public get-login-password --region "$PUBLIC_REGION" $AWS_TIMEOUTS 2>"$work_dir/err" |
		cosign login "$PUBLIC_REGISTRY" -u AWS --password-stdin >"$work_dir/login" 2>&1 || rc=$?
	if ((rc != 0)); then
		sed 's/^/  /' "$work_dir/err" "$work_dir/login" >&2 || true
		fail "could not log in to $PUBLIC_REGISTRY (exit $rc)"
	fi
	ok "logged in to $PUBLIC_REGISTRY (publish role)"

	# A re-run of this job: the earlier attempt may have signed already. Any failure here (no signature yet, or a
	# read that failed) just means sign: a second signature from the same workflow is harmless.
	if check_signature; then
		ok "$PUBLIC_REPO@$DIGEST is already signed by $identity"
		return 0
	fi

	cosign sign --yes --oidc-provider github-actions "$PUBLIC_REPO@$DIGEST" >"$work_dir/sign" 2>&1 || rc=$?
	if ((rc != 0)); then
		sed 's/^/  /' "$work_dir/sign" >&2 || true
		fail "could not sign $PUBLIC_REPO@$DIGEST (cosign exit $rc)"
	fi
	if ! check_signature_with_retries; then
		sed 's/^/  /' "$work_dir/verify" >&2 || true
		fail "signed $PUBLIC_REPO@$DIGEST, but its signature does not verify as $identity (checked $VERIFY_ATTEMPTS times)"
	fi
	ok "signed $PUBLIC_REPO@$DIGEST as $identity"
}

cmd_verify() {
	local name
	for name in $CREDENTIAL_VARS; do
		if [[ -n "${!name:-}" ]]; then
			fail "$name is set; this check must run with no AWS credentials"
		fi
	done
	if [[ "${AWS_EC2_METADATA_DISABLED:-}" != true ]]; then
		fail "AWS_EC2_METADATA_DISABLED must be true, so no credentials come from the runner's instance metadata"
	fi
	check_retry_scale
	require_target
	make_work_dir
	# An empty DOCKER_CONFIG: no saved login can reach cosign.
	private_docker_config
	if ! check_signature_with_retries; then
		sed 's/^/  /' "$work_dir/verify" >&2 || true
		fail "$PUBLIC_REPO@$DIGEST has no signature from $identity (checked $VERIFY_ATTEMPTS times, anonymously)"
	fi
	ok "$PUBLIC_REPO@$DIGEST is signed by $identity (checked anonymously)"
}

# --- main --------------------------------------------------------------------------------------------------------

case "${1:-}" in
install-cosign) cmd_install_cosign ;;
sign) cmd_sign ;;
verify) cmd_verify ;;
*)
	echo "usage: $0 install-cosign | sign | verify" >&2
	exit 2
	;;
esac
