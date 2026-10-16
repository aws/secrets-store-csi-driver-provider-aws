#!/usr/bin/env bash
#
# The Release workflow's steps against the private staging repo (<account>.dkr.ecr.<region>.amazonaws.com/ascp).
# One command per call:
#
#   no-env-credentials  fails if AWS keys are in the job environment (they must only come from step outputs)
#   check-free          fails if STAGE_TAG is already in the repo
#   login               docker login to the registry
#   logout              docker logout from the registry (a quiet success if there is nothing to log out of)
#   check-build         checks the image the build pushed, then writes digest=<DIGEST> to $GITHUB_OUTPUT
#   stage               adds STAGE_TAG to DIGEST, without rebuilding or copying anything
#
# Inputs (environment):
#   IMAGE_REPO          <account>.dkr.ecr.<region>.amazonaws.com/ascp (all but no-env-credentials)
#   AWS_REGION          must be the repo's region (check-free, login, check-build, stage)
#   AWS_RETRY_MODE, AWS_MAX_ATTEMPTS   must be set; the AWS CLI does the retries (check-free, login, check-build,
#                       stage)
#   PRACTICE            true or false (check-free, check-build, stage)
#   STAGE_TAG           X.Y.Z, or rehearsal-<run id> in a practice run (check-free, stage)
#   DIGEST              sha256:<64 hex>, the image index (check-build, stage)
#   TESTING_TAG         the tag the build pushed, which DIGEST must still carry (check-build, stage)
#   VERSION, ROOTFS, GITHUB_OUTPUT                     (check-build)
#
# A practice image and a real release must never share a digest: ECR's lifecycle rules delete by digest, so the
# rule that removes old practice images would remove the release too. Build labels already make that impossible;
# check-build and stage also refuse a digest that carries a tag of the other mode.
#
# No credentials are written or printed. Bash 3.2 compatible: `set -e` is off inside functions called from `if`,
# `||` or `&&`, so every command's exit status is tested by hand.

set -euo pipefail

readonly REPO_NAME=ascp
readonly REPO_RE='^([0-9]{12})\.dkr\.ecr\.([a-z]{2}(-[a-z]+)+-[0-9])\.amazonaws\.com/ascp$'
readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly RELEASE_TAG_RE='^[0-9]+\.[0-9]+\.[0-9]+(-testing)?$'
readonly REHEARSAL_RE='^rehearsal-[0-9]+$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'
readonly BINARY=bin/secrets-store-csi-driver-provider-aws
readonly MODULE=github.com/aws/secrets-store-csi-driver-provider-aws
readonly INDEX_TYPES="application/vnd.oci.image.index.v1+json application/vnd.docker.distribution.manifest.list.v2+json"
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

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
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

require_digest() {
	require DIGEST
	if [[ ! "$DIGEST" =~ $DIGEST_RE ]]; then
		fail "DIGEST $(printf '%q' "$DIGEST") is not sha256:<64 lowercase hex>"
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

# Sets tags_file to the tags on DIGEST, one per line.
read_digest_tags() {
	local rc=0
	ecr describe-images --image-ids "imageDigest=$DIGEST" || rc=$?
	if ((rc != 0)); then
		show_error
		fail "could not read the tags of $DIGEST (exit $rc)"
	fi
	tags_file="$work_dir/tags"
	if ! jq -r '
		if (.imageDetails | length) != 1 then error("expected 1 image") else . end
		| .imageDetails[0].imageTags // [] | .[]
	' "$work_dir/out" >"$tags_file"; then
		fail "could not read the tags of $DIGEST (unexpected reply)"
	fi
}

# The digest carries TESTING_TAG, the tag this run's build pushed.
check_testing_tag() {
	local tag found=0
	while IFS= read -r tag; do
		if [[ "$tag" == "$TESTING_TAG" ]]; then
			found=1
		fi
	done <"$tags_file"
	if ((found == 0)); then
		fail "$DIGEST doesn't carry the tag $TESTING_TAG (tags: $(tr '\n' ' ' <"$tags_file"))"
	fi
	ok "$DIGEST carries $TESTING_TAG"
}

# A practice image never carries a release tag (X.Y.Z or X.Y.Z-testing), and a real one never carries a
# rehearsal-* tag.
check_mode_separation() {
	local tag bad=""
	while IFS= read -r tag; do
		if [[ "$PRACTICE" == true && "$tag" =~ $RELEASE_TAG_RE ]]; then
			bad=$tag
		elif [[ "$PRACTICE" == false && "$tag" == rehearsal-* ]]; then
			bad=$tag
		fi
		if [[ -n "$bad" ]]; then
			echo "  An admin can remove that one tag with:" >&2
			echo "  aws ecr batch-delete-image --registry-id $registry_id --repository-name $REPO_NAME --region $region --image-ids imageTag=$bad" >&2
			if [[ "$PRACTICE" == true ]]; then
				fail "practice run, but $DIGEST already has the release tag $bad"
			fi
			fail "real run, but $DIGEST already has the practice tag $bad"
		fi
	done <"$tags_file"
	ok "$DIGEST has no tags of the other mode"
}

# Writes DIGEST's manifest, byte for byte, to $work_dir/manifest and sets media_type. Fails unless its sha256 is
# the digest and it is an image index.
read_manifest() {
	local rc=0 hash json_type
	ecr batch-get-image --image-ids "imageDigest=$DIGEST" || rc=$?
	if ((rc != 0)); then
		show_error
		fail "could not read the manifest of $DIGEST (exit $rc)"
	fi
	if ! jq -e '(.failures // []) | length == 0' "$work_dir/out" >/dev/null; then
		jq -c '.failures' "$work_dir/out" >&2 || true
		fail "could not read the manifest of $DIGEST (the reply lists failures)"
	fi
	if ! jq -e '(.images | length) == 1 and (.images[0].imageManifest | type) == "string"' "$work_dir/out" \
		>/dev/null; then
		fail "could not read the manifest of $DIGEST (expected exactly 1 image with a manifest)"
	fi
	if ! jq -j '.images[0].imageManifest' "$work_dir/out" >"$work_dir/manifest"; then
		fail "could not read the manifest of $DIGEST"
	fi
	hash=$(sha256_of "$work_dir/manifest")
	if [[ "sha256:$hash" != "$DIGEST" ]]; then
		fail "the manifest ECR returned hashes to sha256:$hash, not $DIGEST"
	fi
	media_type=$(jq -r '.images[0].imageManifestMediaType // ""' "$work_dir/out")
	if [[ " $INDEX_TYPES " != *" $media_type "* ]]; then
		fail "$DIGEST is not an image index (media type $(printf '%q' "$media_type"))"
	fi
	if ! json_type=$(jq -r '.mediaType // ""' "$work_dir/manifest"); then
		fail "the manifest of $DIGEST is not JSON"
	fi
	if [[ -n "$json_type" && "$json_type" != "$media_type" ]]; then
		fail "the manifest says media type $json_type, ECR says $media_type"
	fi
	ok "$DIGEST is an image index ($media_type)"
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
		| .imageDetails[0].imageDigest | strings
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
	if [[ -n "$tag_digest" ]]; then
		fail "$STAGE_TAG is already staged (at $tag_digest); tags there are permanent, so start a new run"
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

# Checks the pushed image: it is the index the digest names, with exactly linux/amd64 and linux/arm64, the build
# put VERSION into both binaries, and the digest carries the expected testing tag and no tag of the other mode.
cmd_check_build() {
	local entries arch
	parse_repo check-region
	require_retries
	require_practice
	require_digest
	require VERSION TESTING_TAG ROOTFS GITHUB_OUTPUT
	if [[ ! "$VERSION" =~ $VERSION_RE ]]; then
		fail "VERSION $(printf '%q' "$VERSION") is not X.Y.Z"
	fi
	if [[ "$PRACTICE" == true && ! "$TESTING_TAG" =~ ^rehearsal-[0-9]+-testing$ ]]; then
		fail "practice run, but TESTING_TAG $(printf '%q' "$TESTING_TAG") is not rehearsal-<run id>-testing"
	fi
	if [[ "$PRACTICE" == false && "$TESTING_TAG" != "$VERSION-testing" ]]; then
		fail "real run, but TESTING_TAG $(printf '%q' "$TESTING_TAG") is not $VERSION-testing"
	fi
	make_work_dir

	read_manifest
	read_digest_tags
	check_mode_separation

	if ! entries=$(jq -r '
		.manifests // error("no manifests")
		| map(.platform // error("no platform") | "\(.os)/\(.architecture)\(if .variant then "/" + .variant else "" end)")
		| sort | join(" ")
	' "$work_dir/manifest"); then
		fail "could not read the platforms of $DIGEST"
	fi
	case "$entries" in
	"linux/amd64 linux/arm64" | "linux/amd64 linux/arm64/v8") ok "platforms: $entries" ;;
	*) fail "expected exactly linux/amd64 and linux/arm64, found: ${entries:-nothing}" ;;
	esac

	if [[ ! -d "$ROOTFS" ]]; then
		fail "the build's local copy $ROOTFS is missing"
	fi
	entries=$(find "$ROOTFS" -mindepth 1 -maxdepth 1 -exec basename {} \; | sort | tr '\n' ' ')
	if [[ "$entries" != "linux_amd64 linux_arm64 " ]]; then
		fail "expected exactly linux_amd64/ and linux_arm64/ in $ROOTFS, found: ${entries:-nothing}"
	fi
	for arch in amd64 arm64; do
		check_binary "$arch" "$ROOTFS/linux_$arch/$BINARY"
	done

	check_testing_tag

	echo "digest=$DIGEST" >>"$GITHUB_OUTPUT"
	ok "checked $IMAGE_REPO@$DIGEST"
}

# check_binary <arch> <path> : the binary was built for linux/<arch> without cgo and with VERSION stamped in.
check_binary() {
	local arch=$1 path=$2 info ldflags count name setting
	local build=$'\tbuild\t' # how `go version -m` starts a build setting line
	if [[ ! -f "$path" || -L "$path" ]]; then
		fail "linux_$arch has no regular file at $BINARY"
	fi
	if ! info=$(go version -m "$path" 2>&1); then
		printf '%s\n' "$info" | head -5 >&2 || true
		fail "go version -m failed for the $arch binary"
	fi
	for setting in "GOOS=linux" "GOARCH=$arch" "CGO_ENABLED=0"; do
		count=$(printf '%s\n' "$info" | grep -cxF "$build$setting" || true)
		if [[ "$count" != 1 ]]; then
			fail "the $arch binary wasn't built with $setting"
		fi
	done
	count=$(printf '%s\n' "$info" | grep -cF "$build-ldflags=" || true)
	if [[ "$count" != 1 ]]; then
		fail "the $arch binary has $count -ldflags build settings, expected 1"
	fi
	ldflags=$(printf '%s\n' "$info" | grep -F "$build-ldflags=")
	ldflags=${ldflags#"$build"-ldflags=}
	if [[ "$ldflags" == \"*\" ]]; then
		ldflags=${ldflags#\"}
		ldflags=${ldflags%\"}
	fi
	for name in Version ProviderVersion; do
		if [[ " $ldflags " != *" -X '$MODULE/server.$name=$VERSION' "* ]]; then
			fail "the $arch binary's server.$name isn't $VERSION (ldflags: $ldflags)"
		fi
	done
	ok "$arch binary: linux/$arch, no cgo, version $VERSION"
}

cmd_stage() {
	local rc=0
	parse_repo check-region
	require_retries
	require_practice
	require_stage_tag
	require_digest
	require TESTING_TAG
	if [[ "$TESTING_TAG" != "$STAGE_TAG-testing" ]]; then
		fail "TESTING_TAG $(printf '%q' "$TESTING_TAG") is not $STAGE_TAG-testing"
	fi
	make_work_dir

	read_digest_tags
	check_mode_separation
	# The digest must still be this run's build: a later build of the same version moves the -testing tag.
	check_testing_tag

	read_stage_tag
	if [[ "$tag_digest" == "$DIGEST" ]]; then
		ok "$STAGE_TAG is already staged at $DIGEST"
		echo "$IMAGE_REPO:$STAGE_TAG@$DIGEST"
		return 0
	fi
	if [[ -n "$tag_digest" ]]; then
		fail "$STAGE_TAG already points at $tag_digest, not $DIGEST"
	fi

	read_manifest
	ecr put-image --image-tag "$STAGE_TAG" --image-digest "$DIGEST" --image-manifest "file://$work_dir/manifest" \
		--image-manifest-media-type "$media_type" || rc=$?
	if ((rc != 0)); then
		if error_is ImageTagAlreadyExistsException || error_is ImageAlreadyExistsException; then
			echo "  the tag already exists; checking where it points" >&2
		else
			show_error
			fail "could not add $STAGE_TAG to $DIGEST (exit $rc)"
		fi
	fi

	read_stage_tag
	if [[ "$tag_digest" != "$DIGEST" ]]; then
		fail "after staging, $STAGE_TAG points at ${tag_digest:-nothing}, not $DIGEST"
	fi
	ok "staged $STAGE_TAG"
	echo "$IMAGE_REPO:$STAGE_TAG@$DIGEST"
}

# --- main --------------------------------------------------------------------------------------------------------

case "${1:-}" in
no-env-credentials) cmd_no_env_credentials ;;
check-free) cmd_check_free ;;
login) cmd_login ;;
logout) cmd_logout ;;
check-build) cmd_check_build ;;
stage) cmd_stage ;;
*)
	echo "usage: $0 no-env-credentials | check-free | login | logout | check-build | stage" >&2
	exit 2
	;;
esac
