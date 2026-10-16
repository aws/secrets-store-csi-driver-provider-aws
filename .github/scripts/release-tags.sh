#!/usr/bin/env bash
#
# Works out the image names, build args and labels for one Release run and writes them to $GITHUB_OUTPUT:
#   imageRepo   <registry>/ascp
#   region      the registry's region
#   accountId   the registry's account
#   testingTag  the tag the build pushes: <version>-testing, or rehearsal-<run id>-testing in a practice run
#   stageTag    the tag the stage job adds: <version>, or rehearsal-<run id> in a practice run
#   buildArgs   the LDFLAGS build arg that stamps the version into the binary
#   labels      image labels with the commit, the run id + attempt and the mode, so no two runs (and no practice
#               run and real run) can build the same image digest
#
# The version is checked again here, so a bad value can't reach the build even if this job is re-run on its own.
#
# Inputs (environment): VERSION, PRACTICE (true or false), STAGING_REGISTRY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT,
# GITHUB_SHA, GITHUB_OUTPUT. Bash 3.2 compatible.

set -euo pipefail

readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly MAX_VERSION_LENGTH=32
readonly REGISTRY_RE='^([0-9]{12})\.dkr\.ecr\.([a-z]{2}(-[a-z]+)+-[0-9])\.amazonaws\.com$'
readonly DIGITS_RE='^[0-9]+$'
readonly SHA_RE='^[0-9a-f]{40}$'
readonly MODULE=github.com/aws/secrets-store-csi-driver-provider-aws
readonly LABEL_PREFIX=com.amazonaws.secrets-store-csi-driver-provider-aws.release

fail() {
	echo "✘ $*"
	exit 1
}

for name in VERSION PRACTICE STAGING_REGISTRY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_SHA GITHUB_OUTPUT; do
	if [[ -z "${!name:-}" ]]; then
		fail "$name is not set"
	fi
done

if ((${#VERSION} > MAX_VERSION_LENGTH)) || [[ ! "$VERSION" =~ $VERSION_RE ]]; then
	fail "$(printf '%q' "$VERSION") is not a valid version (X.Y.Z)"
fi
case "$PRACTICE" in
true) mode=practice ;;
false) mode=real ;;
*) fail "PRACTICE must be true or false, not $(printf '%q' "$PRACTICE")" ;;
esac
if [[ ! "$STAGING_REGISTRY" =~ $REGISTRY_RE ]]; then
	fail "STAGING_REGISTRY $(printf '%q' "$STAGING_REGISTRY") is not <account>.dkr.ecr.<region>.amazonaws.com"
fi
account_id=${BASH_REMATCH[1]}
region=${BASH_REMATCH[2]}
for name in GITHUB_RUN_ID GITHUB_RUN_ATTEMPT; do
	if [[ ! "${!name}" =~ $DIGITS_RE ]]; then
		fail "$name $(printf '%q' "${!name}") is not a number"
	fi
done
if [[ ! "$GITHUB_SHA" =~ $SHA_RE ]]; then
	fail "GITHUB_SHA $(printf '%q' "$GITHUB_SHA") is not a 40-character commit id"
fi

if [[ "$mode" == practice ]]; then
	stage_tag="rehearsal-$GITHUB_RUN_ID"
else
	stage_tag=$VERSION
fi
testing_tag="$stage_tag-testing"
build_args="LDFLAGS=-X '$MODULE/server.Version=$VERSION' -X '$MODULE/server.ProviderVersion=$VERSION' -extldflags '-static'"
labels="org.opencontainers.image.revision=$GITHUB_SHA
$LABEL_PREFIX.run=$GITHUB_RUN_ID-$GITHUB_RUN_ATTEMPT
$LABEL_PREFIX.mode=$mode"

# Every value was checked above, so none can contain a newline or the delimiter.
{
	echo "imageRepo=$STAGING_REGISTRY/ascp"
	echo "region=$region"
	echo "accountId=$account_id"
	echo "testingTag=$testing_tag"
	echo "stageTag=$stage_tag"
	echo "buildArgs=$build_args"
	echo "labels<<RELEASE_TAGS_EOF"
	echo "$labels"
	echo "RELEASE_TAGS_EOF"
} >>"$GITHUB_OUTPUT"

echo "✔ $mode run"
echo "  image repo:  $STAGING_REGISTRY/ascp"
echo "  build tag:   $testing_tag"
echo "  stage tag:   $stage_tag"
echo "  build args:  $build_args"
echo "  labels:"
printf '%s\n' "$labels" | sed 's/^/    /'
