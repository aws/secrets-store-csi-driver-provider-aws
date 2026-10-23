#!/usr/bin/env bash
#
# The Release workflow's anonymous checks of what it published to ECR Public. One command per call:
#
#   version-tags   reads every version tag with no credentials and checks it serves DIGEST: the index (by its
#                  digest header and by hashing its body), every image in the index (by hashing it) and every
#                  image's config blob
#
# Inputs (environment):
#   PUBLIC_REPO    public.ecr.aws/<namespace>/<name>; the production repo exactly when PRACTICE is false
#   PRACTICE       true or false
#   DIGEST         sha256:<64 hex>, the tested image index from the build job; never a digest read from a registry
#   VERSION_TAGS   the three version tags from public-tags.sh
# Test-only settings: REGISTRY_URL, REGISTRY_RETRY_SCALE, REGISTRY_PACE_SECONDS (see registry-lib.sh), and
# REGISTRY_DEADLINE (default 600: the script stops after 10 minutes).
#
# Anonymous by construction: the script runs only curl and python3 (no AWS CLI, docker or crane), and refuses to
# start if any AWS credential variable is set. The token request carries no Authorization header; every other
# request carries only the anonymous bearer token.
#
# Each read is retried until it shows the tested digest or registry-lib.sh's retry budget runs out: a network
# error, 429, 5xx, 404 and a missing digest header all retry, and every request is paced. A tag that shows any
# other digest is on another image, and the check stops at once. Every failure ends in a ✘ line and exit 1.
#
# Bash 3.2 compatible: `set -e` is off inside functions called from `if`, `||` or `&&`, so every command's exit
# status is tested by hand.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=registry-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"

readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly REHEARSAL_RE='^rehearsal-[0-9]+$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'
# The AWS credential, profile and role variables this check refuses to run with.
readonly CREDENTIAL_VARS="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE
AWS_WEB_IDENTITY_TOKEN_FILE AWS_ROLE_ARN AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE
AWS_CONTAINER_CREDENTIALS_RELATIVE_URI AWS_CONTAINER_CREDENTIALS_FULL_URI"

ok() { echo "✔ $*"; }
fail() {
	echo "✘ $*"
	exit 1
}

REGISTRY_WORK_DIR=""
cleanup() {
	if [[ -n "$REGISTRY_WORK_DIR" ]]; then
		rm -rf "$REGISTRY_WORK_DIR"
	fi
}
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

require() {
	local name
	for name in "$@"; do
		if [[ -z "${!name:-}" ]]; then
			fail "$name is not set"
		fi
	done
}

# --- inputs ------------------------------------------------------------------------------------------------------

refuse_credentials() {
	local name found=0
	for name in $CREDENTIAL_VARS; do
		if [[ -n "${!name+set}" ]]; then
			echo "✘ $name is set"
			found=1
		fi
	done
	if ((found == 1)); then
		fail "this check must run with no way to get AWS credentials; remove the variables above from the job"
	fi
	ok "no AWS credential variables are set"
}

require_digest() {
	require DIGEST
	if [[ ! "$DIGEST" =~ $DIGEST_RE ]]; then
		fail "DIGEST $(printf '%q' "$DIGEST") is not sha256:<64 lowercase hex>"
	fi
}

# Sets tag_list (an array) from VERSION_TAGS, with the same rules as publish-image.sh.
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

# --- registry reads ----------------------------------------------------------------------------------------------

# Prints sha256:<hex> of a file's bytes.
digest_of() {
	python3 -I -c '
import hashlib, sys
with open(sys.argv[1], "rb") as f:
    print("sha256:" + hashlib.sha256(f.read()).hexdigest())
' "$1"
}

# fetch <what> <http_request args>... : one read with the anonymous token. Anything but the expected status after
# the retries is a failure: 200, or 307 for a blob (the registry redirects blob downloads).
fetch() {
	local what=$1 rc=0
	shift
	http_request --retry-404 "$@" || rc=$?
	if ((rc == REGISTRY_OUT_OF_TIME)); then
		fail "ran out of time reading $what"
	fi
	if ((rc != 0)); then
		fail "could not read $what (see the error above)"
	fi
	case "$REGISTRY_HTTP_STATUS" in
	200) ;;
	307) [[ "${*: -1}" == */blobs/* ]] || fail "could not read $what (HTTP 307)" ;;
	*) fail "could not read $what (HTTP $REGISTRY_HTTP_STATUS)" ;;
	esac
}

# check_tag <tag> : the tag's digest header is DIGEST, and the manifest it serves hashes to DIGEST. Leaves the
# manifest in $REGISTRY_WORK_DIR/index.json.
check_tag() {
	local tag=$1 url="$registry_base/manifests/$1" got
	fetch "$tag" --want-header docker-content-digest --head --header "Authorization: Bearer $REGISTRY_TOKEN" \
		--header "Accept: $REGISTRY_ACCEPT_MANIFEST" "$url"
	got=$(header_value docker-content-digest) || fail "could not read the digest header of $tag"
	if [[ ! "$got" =~ $DIGEST_RE ]]; then
		fail "$tag has the digest header $(printf '%q' "$got"), not sha256:<64 hex>"
	fi
	if [[ "$got" != "$DIGEST" ]]; then
		fail "$tag points at $got, not the tested $DIGEST: it is on another image; stopping"
	fi
	# ECR Public sends the digest header on HEAD only, so the body is hashed as a second, independent check.
	fetch "the manifest of $tag" --header "Authorization: Bearer $REGISTRY_TOKEN" \
		--header "Accept: $REGISTRY_ACCEPT_MANIFEST" "$url"
	got=$(digest_of "$REGISTRY_WORK_DIR/body") || fail "could not hash the manifest of $tag"
	if [[ "$got" != "$DIGEST" ]]; then
		fail "the manifest $tag serves hashes to $got, not the tested $DIGEST: it is on another image; stopping"
	fi
	cp "$REGISTRY_WORK_DIR/body" "$REGISTRY_WORK_DIR/index.json" || fail "could not keep the manifest of $tag"
	ok "$tag points at $DIGEST"
}

# check_image <digest> : the image manifest the index lists hashes to its digest, and its config blob is there.
check_image() {
	local image=$1 got config
	fetch "image $image" --header "Authorization: Bearer $REGISTRY_TOKEN" \
		--header "Accept: $REGISTRY_ACCEPT_MANIFEST" "$registry_base/manifests/$image"
	got=$(digest_of "$REGISTRY_WORK_DIR/body") || fail "could not hash image $image"
	if [[ "$got" != "$image" ]]; then
		fail "image $image serves a manifest that hashes to $got; stopping"
	fi
	if ! config=$(python3 -I -c '
import json, re, sys
try:
    with open(sys.argv[1], "rb") as f:
        digest = json.loads(f.read())["config"]["digest"]
except Exception:
    sys.exit(1)
if not isinstance(digest, str) or not re.fullmatch(r"sha256:[0-9a-f]{64}", digest):
    sys.exit(1)
print(digest)
' "$REGISTRY_WORK_DIR/body"); then
		fail "could not read the config digest of image $image"
	fi
	# A GET, not a HEAD: ECR Public refuses an anonymous HEAD on a blob, and answers a GET with a redirect to the
	# download. The redirect is not followed; it shows the blob is there.
	fetch "the config $config of image $image" --header "Authorization: Bearer $REGISTRY_TOKEN" \
		"$registry_base/blobs/$config"
	ok "image $image and its config $config are public"
}

# --- commands ----------------------------------------------------------------------------------------------------

cmd_version_tags() {
	local rc=0 tag images image
	refuse_credentials
	check_target || exit 1
	require_digest
	require_version_tags
	REGISTRY_REPO_PATH=${PUBLIC_REPO#public.ecr.aws/}
	REGISTRY_DEADLINE=${REGISTRY_DEADLINE:-600}
	registry_base="${REGISTRY_URL:-https://public.ecr.aws}/v2/$REGISTRY_REPO_PATH"
	REGISTRY_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/verify-public-image.XXXXXX") ||
		fail "could not create a temp directory"

	get_token || rc=$?
	if ((rc == REGISTRY_OUT_OF_TIME)); then
		fail "ran out of time getting an anonymous token for $PUBLIC_REPO"
	fi
	if ((rc != 0)); then
		fail "could not get an anonymous token for $PUBLIC_REPO (see the error above)"
	fi

	for tag in "${tag_list[@]}"; do
		check_tag "$tag"
	done

	# All three tags serve the same index (checked above), so its images are checked once.
	check_platforms "$REGISTRY_WORK_DIR/index.json" "$PUBLIC_REPO@$DIGEST" || exit 1
	if ! images=$(python3 -I -c '
import json, re, sys
try:
    with open(sys.argv[1], "rb") as f:
        digests = [entry["digest"] for entry in json.loads(f.read())["manifests"]]
except Exception:
    sys.exit(1)
if not digests or not all(isinstance(d, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", d) for d in digests):
    sys.exit(1)
print("\n".join(digests))
' "$REGISTRY_WORK_DIR/index.json"); then
		fail "could not read the images listed in $PUBLIC_REPO@$DIGEST"
	fi
	for image in $images; do
		check_image "$image"
	done

	ok "$PUBLIC_REPO@$DIGEST is public as ${tag_list[*]}, with every image and config it lists"
}

# --- main --------------------------------------------------------------------------------------------------------

case "${1:-}" in
version-tags) cmd_version_tags ;;
*)
	echo "usage: $0 version-tags" >&2
	exit 2
	;;
esac
