#!/usr/bin/env bash
#
# The Release workflow's steps against the private staging repo (<account>.dkr.ecr.<region>.amazonaws.com/ascp).
# One command per call:
#
#   no-env-credentials  fails if AWS keys are in the job environment (they must only come from step outputs)
#   check-free          fails if STAGE_TAG is already in the repo
#   login               docker login to the registry
#   logout              docker logout from the registry (a quiet success if there is nothing to log out of)
#
# Inputs (environment):
#   IMAGE_REPO          <account>.dkr.ecr.<region>.amazonaws.com/ascp (all but no-env-credentials)
#   AWS_REGION          must be the repo's region (check-free, login)
#   AWS_RETRY_MODE, AWS_MAX_ATTEMPTS   must be set; the AWS CLI does the retries (check-free, login)
#   PRACTICE            true or false (check-free)
#   STAGE_TAG           X.Y.Z, or rehearsal-<run id> in a practice run (check-free)
#
# No credentials are written or printed. Bash 3.2 compatible: `set -e` is off inside functions called from `if`,
# `||` or `&&`, so every command's exit status is tested by hand.

set -euo pipefail

readonly REPO_NAME=ascp
readonly REPO_RE='^([0-9]{12})\.dkr\.ecr\.([a-z]{2}(-[a-z]+)+-[0-9])\.amazonaws\.com/ascp$'
readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly REHEARSAL_RE='^rehearsal-[0-9]+$'
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
	work_dir=$(mktemp -d "${TMPDIR:-/tmp}/staging-image.XXXXXX") || fail "could not create a temp directory"
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

# Sets registry_id, registry and region from IMAGE_REPO. With "check-region", AWS_REGION must match.
parse_repo() {
	require IMAGE_REPO
	if [[ ! "$IMAGE_REPO" =~ $REPO_RE ]]; then
		fail "IMAGE_REPO $(printf '%q' "$IMAGE_REPO") is not <account>.dkr.ecr.<region>.amazonaws.com/$REPO_NAME"
	fi
	registry_id=${BASH_REMATCH[1]}
	region=${BASH_REMATCH[2]}
	registry=${IMAGE_REPO%/*}
	if [[ "${1:-}" == check-region ]]; then
		require AWS_REGION
		if [[ "$AWS_REGION" != "$region" ]]; then
			fail "AWS_REGION $(printf '%q' "$AWS_REGION") is not the repo's region ($region)"
		fi
	fi
}

require_retries() {
	require AWS_RETRY_MODE AWS_MAX_ATTEMPTS
}

require_practice() {
	require PRACTICE
	if [[ "$PRACTICE" != true && "$PRACTICE" != false ]]; then
		fail "PRACTICE must be true or false, not $(printf '%q' "$PRACTICE")"
	fi
}

# STAGE_TAG is X.Y.Z in a real run and rehearsal-<run id> in a practice run, nothing else.
require_stage_tag() {
	require STAGE_TAG
	if [[ "$PRACTICE" == true && ! "$STAGE_TAG" =~ $REHEARSAL_RE ]]; then
		fail "practice run, but STAGE_TAG $(printf '%q' "$STAGE_TAG") is not rehearsal-<run id>"
	fi
	if [[ "$PRACTICE" == false && ! "$STAGE_TAG" =~ $VERSION_RE ]]; then
		fail "real run, but STAGE_TAG $(printf '%q' "$STAGE_TAG") is not X.Y.Z"
	fi
}

# --- AWS calls ---------------------------------------------------------------------------------------------------

# ecr <operation> <args>... : runs one ECR call on the staging repo. Its output goes to $work_dir/out and its
# errors to $work_dir/err. Returns the CLI's exit status.
ecr() {
	local operation=$1 rc=0
	shift
	# shellcheck disable=SC2086 # AWS_TIMEOUTS is split into its flags on purpose
	aws ecr "$operation" --registry-id "$registry_id" --repository-name "$REPO_NAME" --region "$region" "$@" \
		--output json $AWS_TIMEOUTS >"$work_dir/out" 2>"$work_dir/err" || rc=$?
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

# Sets tag_digest to the digest STAGE_TAG points at, or "" if the tag isn't in the repo.
read_stage_tag() {
	local rc=0
	tag_digest=""
	ecr describe-images --image-ids "imageTag=$STAGE_TAG" || rc=$?
	if ((rc != 0)); then
		if error_is ImageNotFoundException; then
			return 0
		fi
		show_error
		fail "could not check $STAGE_TAG (exit $rc)"
	fi
	if ! tag_digest=$(jq -er '
		if (.imageDetails | length) != 1 then error("expected 1 image") else . end
		| .imageDetails[0].imageDigest | select(type == "string" and test("^sha256:[0-9a-f]{64}$"))
	' "$work_dir/out"); then
		fail "could not check $STAGE_TAG (unexpected reply)"
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

cmd_check_free() {
	parse_repo check-region
	require_retries
	require_practice
	require_stage_tag
	make_work_dir
	read_stage_tag
	if [[ -n "$tag_digest" && "$PRACTICE" == true ]]; then
		fail "$STAGE_TAG is already staged (at $tag_digest); tags there are permanent, so start a new run"
	fi
	if [[ -n "$tag_digest" ]]; then
		fail "$STAGE_TAG is already staged (at $tag_digest); tags there are permanent, so re-run the failed jobs" \
			"of the run that staged it, or release a new version"
	fi
	ok "$STAGE_TAG is free"
}

cmd_login() {
	local rc=0
	parse_repo check-region
	require_retries
	make_work_dir
	# The password goes straight from aws into docker; neither command's output is printed unless it fails.
	# shellcheck disable=SC2086 # AWS_TIMEOUTS is split into its flags on purpose
	aws ecr get-login-password --region "$region" $AWS_TIMEOUTS 2>"$work_dir/err" |
		docker login --username AWS --password-stdin "$registry" >"$work_dir/docker" 2>&1 || rc=$?
	if ((rc != 0)); then
		show_error
		sed 's/^/  /' "$work_dir/docker" >&2 || true
		fail "could not log in to $registry (exit $rc)"
	fi
	ok "logged in to $registry"
}

cmd_logout() {
	local rc=0 out
	if [[ -z "${IMAGE_REPO:-}" ]]; then
		echo "nothing to log out of (no image repo)"
		return 0
	fi
	parse_repo
	# Prints "Not logged in to ..." and succeeds when there was no login.
	out=$(docker logout "$registry" 2>&1) || rc=$?
	echo "$out"
	if ((rc != 0)); then
		fail "docker logout $registry failed (exit $rc)"
	fi
}

# --- main --------------------------------------------------------------------------------------------------------

case "${1:-}" in
no-env-credentials) cmd_no_env_credentials ;;
check-free) cmd_check_free ;;
login) cmd_login ;;
logout) cmd_logout ;;
*)
	echo "usage: $0 no-env-credentials | check-free | login | logout" >&2
	exit 2
	;;
esac
