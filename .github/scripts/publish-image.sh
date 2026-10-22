#!/usr/bin/env bash
#
# The Release workflow's steps that publish the tested image to ECR Public. One command per call:
#
#   no-env-credentials     fails if AWS keys are in the job environment (they must only come from step outputs)
#   role-accounts          checks both role ARNs and writes publishAccountId and pullAccountId to $GITHUB_OUTPUT
#   precheck-version-tags  reads all the version tags before anything is written; fails if any is on another digest
#   copy-version-tags      copies DIGEST from the staging repo to the public repo under the version tags, reading
#                          each one back, then writes publicRepo to $GITHUB_OUTPUT
#
# Inputs (environment). precheck-version-tags and copy-version-tags:
#   PUBLIC_REPO            public.ecr.aws/<namespace>/<name>; the production repo exactly when PRACTICE is false
#   PRACTICE               true or false
#   DIGEST                 sha256:<64 hex>, the tested image index
#   VERSION_TAGS           the three version tags from public-tags.sh
#   PUBLISH_ACCOUNT_ID     the public repo's account, from role-accounts
#   AWS_RETRY_MODE, AWS_MAX_ATTEMPTS   must be set; the AWS CLI does the retries
#   AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN   the publish role's credentials, on the step's env:
# copy-version-tags only:
#   IMAGE_REPO             <account>.dkr.ecr.<region>.amazonaws.com/ascp, the staging repo
#   STAGING_PULL_ROLE_ARN  the read-only role in the staging account that the publish role assumes
#   GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT   name and tag the pull role session
#   RUNNER_TEMP, GITHUB_OUTPUT
#   crane on the PATH
# role-accounts: PUBLISH_ROLE_ARN, STAGING_PULL_ROLE_ARN, GITHUB_OUTPUT
# Test-only setting: REGISTRY_RETRY_SCALE multiplies the read-back pause (0 in tests).
#
# Credentials: the publish role's keys come in on the step's env:. copy-version-tags assumes the pull role itself
# and keeps those keys in shell variables: each aws call that needs them gets them on that one command, nothing is
# exported, and only the AWS error name of a failed assume-role is printed. crane's logins go to a temporary
# DOCKER_CONFIG under RUNNER_TEMP, always removed on exit, never ~/.docker. Passwords reach crane on stdin only.
#
# Every version tag is read before anything is written, re-checked right before it is written and read back right
# after (see read_back). A tag on a digest that this run did not put there stops the run at once.
#
# Bash 3.2 compatible: `set -e` is off inside functions called from `if`, `||` or `&&`, so every command's exit
# status is tested by hand.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=registry-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"

readonly STAGING_REPO_RE='^([0-9]{12})\.dkr\.ecr\.([a-z]{2}(-[a-z]+)+-[0-9])\.amazonaws\.com/ascp$'
readonly ROLE_ARN_RE='^arn:aws:iam::([0-9]{12}):role/([A-Za-z0-9+=,.@_-]+/)*[A-Za-z0-9+=,.@_-]{1,64}$'
readonly ASSUMED_ARN_RE='^arn:aws:sts::([0-9]{12}):assumed-role/[A-Za-z0-9+=,.@_-]+/[A-Za-z0-9+=,.@_-]+$'
readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly RELEASE_TAG_RE='^[0-9]+\.[0-9]+\.[0-9]+(-testing)?$'
readonly REHEARSAL_RE='^rehearsal-[0-9]+$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'
readonly ACCOUNT_RE='^[0-9]{12}$'
readonly DIGITS_RE='^[0-9]+$'
readonly WHOLE_NUMBER_RE='^(0|[1-9][0-9]*)$' # no leading zero: bash arithmetic would read one as octal
readonly GITHUB_REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
readonly MODE_LABEL=com.amazonaws.secrets-store-csi-driver-provider-aws.release.mode
readonly PUBLIC_REGISTRY=public.ecr.aws
readonly PUBLIC_REGION=us-east-1 # where ECR Public's auth and the CLI's ecr-public commands are used here
readonly AWS_TIMEOUTS="--cli-read-timeout 30 --cli-connect-timeout 10"
# The read-back budget is an estimate. read_back logs each read that doesn't match yet, so tune these values from what
# the run logs show.
readonly READ_BACK_ATTEMPTS=6
readonly READ_BACK_PAUSE=5

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

require_publish_account() {
	require PUBLISH_ACCOUNT_ID
	if [[ ! "$PUBLISH_ACCOUNT_ID" =~ $ACCOUNT_RE ]]; then
		fail "PUBLISH_ACCOUNT_ID $(printf '%q' "$PUBLISH_ACCOUNT_ID") is not a 12-digit account ID"
	fi
}

# Sets staging_account, staging_region and staging_registry from IMAGE_REPO.
parse_staging_repo() {
	require IMAGE_REPO
	if [[ ! "$IMAGE_REPO" =~ $STAGING_REPO_RE ]]; then
		fail "IMAGE_REPO $(printf '%q' "$IMAGE_REPO") is not <account>.dkr.ecr.<region>.amazonaws.com/ascp"
	fi
	staging_account=${BASH_REMATCH[1]}
	staging_region=${BASH_REMATCH[2]}
	staging_registry=${IMAGE_REPO%/*}
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
# These reads name the repo by account (from PUBLISH_ROLE_ARN) and crane writes to PUBLIC_REPO; the environment's
# variables name the same repo.
ecr_public() {
	local operation=$1 rc=0
	shift
	# shellcheck disable=SC2086 # AWS_TIMEOUTS is split into its flags on purpose
	aws ecr-public "$operation" --registry-id "$PUBLISH_ACCOUNT_ID" --repository-name "$public_name" \
		--region "$PUBLIC_REGION" "$@" --output json $AWS_TIMEOUTS >"$work_dir/out" 2>"$work_dir/err" || rc=$?
	return "$rc"
}

# with_pull_credentials <command>... : runs one command with the pull role's credentials, set on that command only.
with_pull_credentials() {
	AWS_ACCESS_KEY_ID=$pull_key_id AWS_SECRET_ACCESS_KEY=$pull_secret AWS_SESSION_TOKEN=$pull_token "$@"
}

# The last call failed with this AWS error name (not just any failure).
error_is() {
	grep -qF "An error occurred ($1)" "$work_dir/err"
}

# Prints the AWS error name of the last call, or "no AWS error name", and nothing else from it.
error_name() {
	local name
	name=$(sed -nE 's/.*An error occurred \(([A-Za-z0-9.]+)\).*/\1/p' "$work_dir/err" | head -n 1 || true)
	echo "${name:-no AWS error name}"
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

# read_back <tag> <expected> <tolerated>... : after a write, reads the tag until it shows <expected>. A value in
# <tolerated> ("null" means absent) is a read that hasn't caught up yet: retried, up to READ_BACK_ATTEMPTS reads
# READ_BACK_PAUSE seconds apart, then a failure. Any other digest is a failure at once, never retried. Every read is printed, so a run's log shows how long the write took to become visible.
read_back() {
	local tag=$1 expected=$2 attempt=1 value known tolerated
	shift 2
	while :; do
		read_public_tag "$tag"
		value=${tag_digest:-null}
		echo "  read back $tag (attempt $attempt): ${tag_digest:-absent}" >&2
		if [[ "$value" == "$expected" ]]; then
			ok "$tag points at $expected"
			return 0
		fi
		known=0
		for tolerated in "$@"; do
			if [[ "$value" == "$tolerated" ]]; then
				known=1
			fi
		done
		if ((known == 0)); then
			fail "after the write, $tag points at $value, not $expected; stopping"
		fi
		if ((attempt >= READ_BACK_ATTEMPTS)); then
			fail "write not visible after $attempt attempts: $tag still reads as ${tag_digest:-absent}, not $expected"
		fi
		sleep $((READ_BACK_PAUSE * ${REGISTRY_RETRY_SCALE:-1}))
		attempt=$((attempt + 1))
	done
}

# Assumes STAGING_PULL_ROLE_ARN with the publish credentials and sets pull_key_id, pull_secret and pull_token.
# The reply goes to a file in the private work_dir, never to stdout; on failure only the AWS error name is printed.
assume_pull_role() {
	local rc=0 values arn session_account
	# shellcheck disable=SC2086 # AWS_TIMEOUTS is split into its flags on purpose
	aws sts assume-role \
		--role-arn "$STAGING_PULL_ROLE_ARN" \
		--role-session-name "ascp-publish-$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT" \
		--duration-seconds 3600 \
		--tags "Key=Repository,Value=$GITHUB_REPOSITORY" "Key=RunId,Value=$GITHUB_RUN_ID" \
		--region "$PUBLIC_REGION" --output json $AWS_TIMEOUTS \
		>"$work_dir/pull-creds.json" 2>"$work_dir/pull-creds.err" || rc=$?
	if ((rc != 0)); then
		cp "$work_dir/pull-creds.err" "$work_dir/err"
		fail "could not assume the pull role $STAGING_PULL_ROLE_ARN ($(error_name), exit $rc)"
	fi
	if ! values=$(python3 -I -c '
import json, sys
try:
    reply = json.load(open(sys.argv[1]))
    creds = reply["Credentials"]
    values = [creds["AccessKeyId"], creds["SecretAccessKey"], creds["SessionToken"], reply["AssumedRoleUser"]["Arn"]]
except Exception:
    sys.exit(1)
if not all(isinstance(v, str) and v and not any(c.isspace() for c in v) for v in values):
    sys.exit(1)
print("\n".join(values))
' "$work_dir/pull-creds.json"); then
		fail "could not read the pull role's credentials (unexpected reply)"
	fi
	rm -f "$work_dir/pull-creds.json"
	pull_key_id=${values%%$'\n'*}
	values=${values#*$'\n'}
	pull_secret=${values%%$'\n'*}
	values=${values#*$'\n'}
	pull_token=${values%%$'\n'*}
	arn=${values#*$'\n'}
	# A backstop: GitHub hides these in every later log line.
	echo "::add-mask::$pull_key_id"
	echo "::add-mask::$pull_secret"
	echo "::add-mask::$pull_token"
	if [[ ! "$arn" =~ $ASSUMED_ARN_RE ]]; then
		fail "the pull role session is $(printf '%q' "$arn"), not an assumed-role ARN"
	fi
	session_account=${BASH_REMATCH[1]}
	if [[ "$session_account" != "$pull_account" ]]; then
		fail "the pull role session is in account $session_account, not $pull_account"
	fi
	ok "assumed the pull role in account $pull_account"
}

# crane_login <registry> <role> <command>... : logs crane in to the registry, the password piped straight from the
# command (an aws get-login-password call) to crane's stdin.
crane_login() {
	local registry=$1 role=$2 rc=0
	shift 2
	"$@" 2>"$work_dir/err" | crane auth login "$registry" -u AWS --password-stdin >"$work_dir/crane" 2>&1 || rc=$?
	if ((rc != 0)); then
		show_error
		sed 's/^/  /' "$work_dir/crane" >&2 || true
		fail "could not log in to $registry (exit $rc)"
	fi
	ok "logged in to $registry ($role)"
}

# Points crane at a new, private DOCKER_CONFIG under RUNNER_TEMP and logs it in to both registries.
crane_logins() {
	docker_config=$(mktemp -d "$RUNNER_TEMP/dc.XXXXXX") || fail "could not create a temp DOCKER_CONFIG"
	# crane reads DOCKER_CONFIG from its own environment; without the export both logins would go to ~/.docker.
	export DOCKER_CONFIG=$docker_config
	# shellcheck disable=SC2086 # AWS_TIMEOUTS is split into its flags on purpose
	crane_login "$staging_registry" 'pull role' \
		with_pull_credentials aws ecr get-login-password --region "$staging_region" $AWS_TIMEOUTS
	# shellcheck disable=SC2086 # AWS_TIMEOUTS is split into its flags on purpose
	crane_login "$PUBLIC_REGISTRY" 'publish role' aws ecr-public get-login-password --region "$PUBLIC_REGION" $AWS_TIMEOUTS
}

# run_crane <what> <args>... : runs one crane command, output to $work_dir/crane-out. Fails with its output.
run_crane() {
	local what=$1 rc=0
	shift
	crane "$@" >"$work_dir/crane-out" 2>"$work_dir/crane-err" || rc=$?
	if ((rc != 0)); then
		sed 's/^/  /' "$work_dir/crane-err" >&2 || true
		fail "could not $what (crane exit $rc)"
	fi
}

# The source digest carries this run's mode, by two independent signals: its tags in the staging repo (as the
# staging steps check them), and the mode label of both images in the index.
check_source_mode() {
	local rc=0 tag bad="" found=0 arch label expected
	# shellcheck disable=SC2086 # AWS_TIMEOUTS is split into its flags on purpose
	with_pull_credentials aws ecr describe-images --registry-id "$staging_account" --repository-name ascp \
		--region "$staging_region" --image-ids "imageDigest=$DIGEST" --output json \
		$AWS_TIMEOUTS >"$work_dir/out" 2>"$work_dir/err" || rc=$?
	if ((rc != 0)); then
		show_error
		fail "could not read the tags of $IMAGE_REPO@$DIGEST (exit $rc)"
	fi
	if ! jq -r '
		if (.imageDetails | length) != 1 then error("expected 1 image") else . end
		| .imageDetails[0].imageTags // [] | .[]
	' "$work_dir/out" >"$work_dir/tags"; then
		fail "could not read the tags of $IMAGE_REPO@$DIGEST (unexpected reply)"
	fi
	# Same tag rule as staging-image.sh's check_mode_separation; keep the two in step.
	while IFS= read -r tag; do
		if [[ "$PRACTICE" == true && "$tag" =~ $RELEASE_TAG_RE ]]; then
			bad=$tag
		elif [[ "$PRACTICE" == false && "$tag" == rehearsal-* ]]; then
			bad=$tag
		fi
		# The stage tag is the first version tag: release-tags.sh's stageTag, named again by public-tags.sh.
		if [[ "$tag" == "${tag_list[0]}" ]]; then
			found=1
		fi
	done <"$work_dir/tags"
	if [[ -n "$bad" && "$PRACTICE" == true ]]; then
		fail "practice run, but $IMAGE_REPO@$DIGEST has the release tag $bad"
	fi
	if [[ -n "$bad" ]]; then
		fail "real run, but $IMAGE_REPO@$DIGEST has the practice tag $bad"
	fi
	if ((found == 0)); then
		fail "$IMAGE_REPO@$DIGEST doesn't carry the stage tag ${tag_list[0]} (tags: $(tr '\n' ' ' <"$work_dir/tags"))"
	fi
	ok "$IMAGE_REPO@$DIGEST is staged as ${tag_list[0]} and has no tags of the other mode"

	expected=real
	if [[ "$PRACTICE" == true ]]; then
		expected=practice
	fi
	for arch in amd64 arm64; do
		run_crane "read the linux/$arch image config of $IMAGE_REPO@$DIGEST" \
			config --platform "linux/$arch" "$IMAGE_REPO@$DIGEST"
		if ! label=$(jq -r --arg key "$MODE_LABEL" '.config.Labels[$key] // "" | strings' "$work_dir/crane-out"); then
			fail "could not read the linux/$arch image config of $IMAGE_REPO@$DIGEST (not JSON)"
		fi
		if [[ "$label" != "$expected" ]]; then
			fail "$expected run, but the linux/$arch image's $MODE_LABEL label is $(printf '%q' "$label")"
		fi
	done
	ok "both images are labelled $MODE_LABEL=$expected"
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
	require_publish_account
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

cmd_copy_version_tags() {
	local tag
	check_target || exit 1
	public_name=${PUBLIC_REPO##*/}
	require_retries
	require_digest
	require_version_tags
	require_publish_account
	parse_staging_repo
	parse_role_arn STAGING_PULL_ROLE_ARN
	pull_account=$role_account
	if [[ "$pull_account" != "$staging_account" ]]; then
		fail "the pull role is in account $pull_account, but the staging repo is in $staging_account"
	fi
	require RUNNER_TEMP GITHUB_REPOSITORY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_OUTPUT
	if [[ ! "$GITHUB_REPOSITORY" =~ $GITHUB_REPO_RE ]]; then
		fail "GITHUB_REPOSITORY $(printf '%q' "$GITHUB_REPOSITORY") is not owner/name"
	fi
	if [[ ! "$GITHUB_RUN_ID" =~ $DIGITS_RE || ! "$GITHUB_RUN_ATTEMPT" =~ $DIGITS_RE ]]; then
		fail "GITHUB_RUN_ID and GITHUB_RUN_ATTEMPT must be numbers"
	fi
	# read_back scales its pause by this, so it must be a whole number.
	if [[ ! "${REGISTRY_RETRY_SCALE:-1}" =~ $WHOLE_NUMBER_RE ]]; then
		fail "REGISTRY_RETRY_SCALE must be a whole number"
	fi
	make_work_dir

	assume_pull_role
	crane_logins
	# Before any public write, and after the staging login it needs.
	check_source_mode

	for tag in "${tag_list[@]}"; do
		# Re-checked right before the write: the pre-check ran in an earlier step.
		read_public_tag "$tag"
		if [[ "$tag_digest" == "$DIGEST" ]]; then
			ok "$tag already points at $DIGEST"
			continue
		fi
		if [[ -n "$tag_digest" ]]; then
			fail "$tag now points at $tag_digest, not $DIGEST; stopping"
		fi
		# Every tag is copied from the staged image with `crane copy`, not `crane tag`.
		run_crane "copy $IMAGE_REPO@$DIGEST to $PUBLIC_REPO:$tag" copy "$IMAGE_REPO@$DIGEST" "$PUBLIC_REPO:$tag"
		# Version tags were absent before this run, so absent is the only other value the read-back accepts.
		read_back "$tag" "$DIGEST" null
	done

	# A last look at what was published. It runs after the writes, so it reports a bad publish rather than
	# preventing one, and it does not retry: a read that doesn't match fails the run safely, and a re-run skips every tag
	# already on DIGEST and repeats only this read.
	# crane refuses a manifest fetched by digest whose bytes don't hash to that digest.
	run_crane "read the manifest of $PUBLIC_REPO@$DIGEST" manifest "$PUBLIC_REPO@$DIGEST"
	check_platforms "$work_dir/crane-out" "$PUBLIC_REPO@$DIGEST" || exit 1

	echo "publicRepo=$PUBLIC_REPO" >>"$GITHUB_OUTPUT"
	ok "published $PUBLIC_REPO@$DIGEST as ${tag_list[*]}"
}

# --- main --------------------------------------------------------------------------------------------------------

case "${1:-}" in
no-env-credentials) cmd_no_env_credentials ;;
role-accounts) cmd_role_accounts ;;
precheck-version-tags) cmd_precheck_version_tags ;;
copy-version-tags) cmd_copy_version_tags ;;
*)
	echo "usage: $0 no-env-credentials | role-accounts | precheck-version-tags | copy-version-tags" >&2
	exit 2
	;;
esac
