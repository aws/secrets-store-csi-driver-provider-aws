#!/usr/bin/env bash
#
# The Release Helm Chart workflow's preflight: refuses to release the chart unless the image its values.yaml names
# is on the production ECR Public repo and anyone can pull it. Reads the registry the way a customer's cluster
# does: an anonymous token, then a HEAD of the image's manifest with it (a HEAD with no token at all may get an
# auth challenge even from a public repo).
#
# Inputs (environment):
#   IMAGE_REPO   values.yaml image.repository; must be exactly the production repo
#   IMAGE_TAG    values.yaml image.tag; must be X.Y.Z
# Test-only settings: REGISTRY_URL, REGISTRY_RETRY_SCALE, REGISTRY_PACE_SECONDS (see registry-lib.sh), and
# REGISTRY_DEADLINE (default 300: the script stops after 5 minutes).
#
# A network error, 429 or 5xx is retried with registry-lib.sh's budget, then fails. A 404 means the tag is not
# published, and a 401 or 403 that the repo is not public: both fail at once. Every failure is an ::error:: line
# and exit 1.
#
# Bash 3.2 compatible: `set -e` is off inside functions called from `if`, `||` or `&&`, so every command's exit
# status is tested by hand.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=registry-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"

readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

ok() { echo "✔ $*"; }
fail() {
	echo "::error::$*"
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

# --- inputs ------------------------------------------------------------------------------------------------------

if [[ "${IMAGE_REPO:-}" != "$REGISTRY_PRODUCTION_REPO" ]]; then
	fail "values.yaml image.repository is $(printf '%q' "${IMAGE_REPO:-}"), not the production repo $REGISTRY_PRODUCTION_REPO"
fi
if [[ ! "${IMAGE_TAG:-}" =~ $VERSION_RE ]]; then
	fail "values.yaml image.tag $(printf '%q' "${IMAGE_TAG:-}") is not a version (X.Y.Z)"
fi
image="$IMAGE_REPO:$IMAGE_TAG"

# --- registry read -----------------------------------------------------------------------------------------------

REGISTRY_REPO_PATH=${IMAGE_REPO#public.ecr.aws/}
REGISTRY_DEADLINE=${REGISTRY_DEADLINE:-300}
REGISTRY_WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/chart-image-public.XXXXXX") || fail "could not create a temp directory"

rc=0
get_token || rc=$?
if ((rc == REGISTRY_OUT_OF_TIME)); then
	fail "ran out of time getting an anonymous token for $IMAGE_REPO"
fi
if ((rc != 0)); then
	fail "could not get an anonymous token for $IMAGE_REPO (see the error above)"
fi

url="${REGISTRY_URL:-https://public.ecr.aws}/v2/$REGISTRY_REPO_PATH/manifests/$IMAGE_TAG"
http_request --head --header "Authorization: Bearer $REGISTRY_TOKEN" --header "Accept: $REGISTRY_ACCEPT_MANIFEST" \
	"$url" || rc=$?
if ((rc == REGISTRY_OUT_OF_TIME)); then
	fail "ran out of time reading $image"
fi
if ((rc != 0)); then
	fail "could not read $image (see the error above)"
fi
case "$REGISTRY_HTTP_STATUS" in
200) ok "$image is public" ;;
404) fail "$image is not published: release the image first, then the chart" ;;
401 | 403) fail "$image is not public (HTTP $REGISTRY_HTTP_STATUS): an anonymous pull is refused" ;;
*) fail "could not read $image (HTTP $REGISTRY_HTTP_STATUS)" ;;
esac
