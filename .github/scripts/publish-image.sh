#!/usr/bin/env bash
#
# The Release workflow's steps that publish the tested image to ECR Public. One command per call:
#
#   no-env-credentials     fails if AWS keys are in the job environment (they must only come from step outputs)
#   role-accounts          checks both role ARNs and writes publishAccountId and pullAccountId to $GITHUB_OUTPUT
#   precheck-version-tags  reads all the version tags before anything is written; fails if any is on another digest
#
# Inputs (environment). precheck-version-tags:
#   PUBLIC_REPO            public.ecr.aws/<namespace>/<name>; the production repo exactly when PRACTICE is false
#   PRACTICE               true or false
#   DIGEST                 sha256:<64 hex>, the tested image index
#   VERSION_TAGS           the three version tags from public-tags.sh
#   PUBLISH_ACCOUNT_ID     the public repo's account, from role-accounts
#   AWS_RETRY_MODE, AWS_MAX_ATTEMPTS   must be set; the AWS CLI does the retries
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN   the publish role's credentials, on the step's env:
# role-accounts: PUBLISH_ROLE_ARN, STAGING_PULL_ROLE_ARN, GITHUB_OUTPUT
#
# None of these commands writes to a registry. Every version tag is read before anything is written: a tag on a
# digest that this run did not put there stops the run.
#
# Bash 3.2 compatible: `set -e` is off inside functions called from `if`, `||` or `&&`, so every command's exit
# status is tested by hand.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=registry-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"

readonly ROLE_ARN_RE='^arn:aws:iam::([0-9]{12}):role/([A-Za-z0-9+=,.@_-]+/)*[A-Za-z0-9+=,.@_-]{1,64}$'
readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly REHEARSAL_RE='^rehearsal-[0-9]+$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'
readonly ACCOUNT_RE='^[0-9]{12}$'
readonly PUBLIC_REGION=us-east-1 # where the CLI's ecr-public commands are used here
readonly AWS_TIMEOUTS="--cli-read-timeout 30 --cli-connect-timeout 10"

ok() { echo "✔ $*"; }
fail() {
	echo "✘ $*"
	exit 1
}

work_dir=""
cleanup() {
	if [[ -n "$work_dir" ]]; then
		rm -rf "$work_dir"
	fi
}
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

make_work_dir() {
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/publish-image.XXXXXX") || fail "could not create a temp directory"
}

require() {
	local name
	for name in "$@"; do
		if [[ -z "${!name:-}" ]]; then
			fail "$name is not set"
		fi
	done
}

# --- inputs ------------------------------------------------------------------------------------------------------

require_retries() {
	require AWS_RETRY_MODE AWS_MAX_ATTEMPTS
}

require_digest() {
	require DIGEST
	if [[ ! "$DIGEST" =~ $DIGEST_RE ]]; then
		fail "DIGEST $(printf '%q' "$DIGEST") is not sha256:<64 lowercase hex>"
	fi
}

# Sets tag_list (an array) from VERSION_TAGS: <base> <base>-linux-amd64 <base>-linux-arm64, where <base> is
# X.Y.Z in a real run and rehearsal-<run id> in a practice run.
require_version_tags() {
	local base
	require VERSION_TAGS
	read -r -a tag_list <<<"$VERSION_TAGS"
	base=${tag_list[0]:-}
	if [[ ${#tag_list[@]} -ne 3 || "${tag_list[1]}" != "$base-linux-amd64" ||
		"${tag_list[2]}" != "$base-linux-arm64" || "$VERSION_TAGS" != "${tag_list[*]}" ]]; then
		fail "VERSION_TAGS $(printf '%q' "$VERSION_TAGS") is not '<tag> <tag>-linux-amd64 <tag>-linux-arm64'"
	fi
	if [[ "$PRACTICE" == true && ! "$base" =~ $REHEARSAL_RE ]]; then
		fail "practice run, but the version tags $VERSION_TAGS are not rehearsal-<run id> tags"
	fi
	if [[ "$PRACTICE" == false && ! "$base" =~ $VERSION_RE ]]; then
		fail "real run, but the version tags $VERSION_TAGS are not X.Y.Z tags"
	fi
}

# parse_role_arn <variable name> : sets role_account to the account in that role ARN.
parse_role_arn() {
	local name=$1
	require "$name"
	if [[ ! "${!name}" =~ $ROLE_ARN_RE ]]; then
		fail "$name $(printf '%q' "${!name}") is not arn:aws:iam::<account>:role/<name>"
	fi
	role_account=${BASH_REMATCH[1]}
}

# --- AWS calls ---------------------------------------------------------------------------------------------------

# ecr_public <operation> <args>... : one ECR Public call on the public repo, with the publish credentials from the
# environment. Output goes to $work_dir/out, errors to $work_dir/err. Returns the CLI's exit status.
# These reads name the repo by account (from PUBLISH_ROLE_ARN); the environment's variables name the same repo.
ecr_public() {
	local operation=$1 rc=0
	shift
	# shellcheck disable=SC2086 # AWS_TIMEOUTS is split into its flags on purpose
	aws ecr-public "$operation" --registry-id "$PUBLISH_ACCOUNT_ID" --repository-name "$public_name" \
		--region "$PUBLIC_REGION" "$@" --output json $AWS_TIMEOUTS >"$work_dir/out" 2>"$work_dir/err" || rc=$?
	return "$rc"
}

# The last call failed with this AWS error name (not just any failure).
error_is() {
	grep -qF "An error occurred ($1)" "$work_dir/err"
}

# Prints the last call's error output (AWS error text; no credentials) to stderr.
show_error() {
	sed 's/^/  /' "$work_dir/err" >&2 || true
}

# read_public_tag <tag> : sets tag_digest to the digest the tag points at in the public repo, or "" if the tag isn't
# there. Any error other than "not found" fails: an error never means the tag is free.
read_public_tag() {
	local tag=$1 rc=0
	tag_digest=""
	ecr_public describe-images --image-ids "imageTag=$tag" || rc=$?
	if ((rc != 0)); then
		if error_is ImageNotFoundException; then
			return 0
		fi
		show_error
		fail "could not read $tag in $PUBLIC_REPO (exit $rc)"
	fi
	if ! tag_digest=$(jq -er '
		if (.imageDetails | length) != 1 then error("expected 1 image") else . end
		| .imageDetails[0].imageDigest | strings
	' "$work_dir/out") || [[ ! "$tag_digest" =~ $DIGEST_RE ]]; then
		fail "could not read $tag in $PUBLIC_REPO (unexpected reply)"
	fi
}

# --- commands ----------------------------------------------------------------------------------------------------

cmd_no_env_credentials() {
	local name found=0
	for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
		if [[ -n "${!name+set}" ]]; then
			echo "✘ $name is set in the job environment"
			found=1
		fi
	done
	if ((found == 1)); then
		fail "AWS credentials must reach steps only through step outputs (check output-env-credentials)"
	fi
	ok "no AWS credentials in the job environment"
}

cmd_role_accounts() {
	local publish_account
	require GITHUB_OUTPUT
	parse_role_arn PUBLISH_ROLE_ARN
	publish_account=$role_account
	parse_role_arn STAGING_PULL_ROLE_ARN
	{
		echo "publishAccountId=$publish_account"
		echo "pullAccountId=$role_account"
	} >>"$GITHUB_OUTPUT"
	ok "publish role in account $publish_account, pull role in account $role_account"
}

cmd_precheck_version_tags() {
	local tag foreign=0
	check_target || exit 1
	public_name=${PUBLIC_REPO##*/}
	require_retries
	require_digest
	require_version_tags
	require PUBLISH_ACCOUNT_ID
	if [[ ! "$PUBLISH_ACCOUNT_ID" =~ $ACCOUNT_RE ]]; then
		fail "PUBLISH_ACCOUNT_ID $(printf '%q' "$PUBLISH_ACCOUNT_ID") is not a 12-digit account ID"
	fi
	make_work_dir

	# Every tag is read before the verdict, so the log names each one on another digest.
	for tag in "${tag_list[@]}"; do
		read_public_tag "$tag"
		if [[ "$tag_digest" == "$DIGEST" ]]; then
			ok "$tag already points at $DIGEST"
		elif [[ -z "$tag_digest" ]]; then
			ok "$tag is free"
		else
			echo "✘ $tag already points at $tag_digest, not $DIGEST"
			foreign=1
		fi
	done
	if ((foreign == 1)); then
		if [[ "$PRACTICE" == true ]]; then
			fail "nothing was written; public tags can't be moved by this workflow, so start a new practice run"
		fi
		fail "nothing was written; a published version can't be replaced, so release a new version"
	fi
	ok "all version tags are free or already on $DIGEST"
}

# --- main --------------------------------------------------------------------------------------------------------

case "${1:-}" in
no-env-credentials) cmd_no_env_credentials ;;
role-accounts) cmd_role_accounts ;;
precheck-version-tags) cmd_precheck_version_tags ;;
*)
	echo "usage: $0 no-env-credentials | role-accounts | precheck-version-tags" >&2
	exit 2
	;;
esac
