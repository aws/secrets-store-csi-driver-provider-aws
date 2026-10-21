#!/usr/bin/env bash
#
# Names the public tags for one Release run and writes them to $GITHUB_OUTPUT. This is the only place they are
# named; every job that needs them runs this again rather than passing a list between jobs.
#
#   versionTags  real run: X.Y.Z X.Y.Z-linux-amd64 X.Y.Z-linux-arm64
#                practice run: P P-linux-amd64 P-linux-arm64, with P = rehearsal-<run id>
#   aliasTags    in write order, latest last:
#                real run: latest-amd64 latest-arm64 latest-linux-amd64 latest-linux-arm64 <major> latest
#                practice run: the same six names, each prefixed "P-"
#   major        X of X.Y.Z. Computed, never a literal: the older majors' aliases (1, 2) stay where they are.
#
# All three version tags point at the same multi-arch index; the -linux-* names are not per-arch images. No "v"
# prefix and no X.Y tag, matching every earlier release. A practice run never names a bare X.Y.Z or an unprefixed
# alias, so it can't move a tag customers use.
#
# Inputs (environment): VERSION, PRACTICE (true or false), GITHUB_RUN_ID, GITHUB_OUTPUT. No network. Bash 3.2
# compatible.

set -euo pipefail

readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly MAX_VERSION_LENGTH=32
readonly DIGITS_RE='^[0-9]+$'

fail() {
	echo "✘ $*"
	exit 1
}

for name in VERSION PRACTICE GITHUB_RUN_ID GITHUB_OUTPUT; do
	if [[ -z "${!name:-}" ]]; then
		fail "$name is not set"
	fi
done

if ((${#VERSION} > MAX_VERSION_LENGTH)) || [[ ! "$VERSION" =~ $VERSION_RE ]]; then
	fail "$(printf '%q' "$VERSION") is not a valid version (X.Y.Z)"
fi
case "$PRACTICE" in
true | false) ;;
*) fail "PRACTICE must be true or false, not $(printf '%q' "$PRACTICE")" ;;
esac
if [[ ! "$GITHUB_RUN_ID" =~ $DIGITS_RE ]]; then
	fail "GITHUB_RUN_ID $(printf '%q' "$GITHUB_RUN_ID") is not a number"
fi

major=${VERSION%%.*}
if [[ ! "$major" =~ $DIGITS_RE ]]; then
	fail "the major version $(printf '%q' "$major") is not bare digits"
fi

if [[ "$PRACTICE" == true ]]; then
	base="rehearsal-$GITHUB_RUN_ID"
	prefix="$base-"
	mode=practice
else
	base=$VERSION
	prefix=""
	mode=real
fi
version_tags="$base $base-linux-amd64 $base-linux-arm64"
alias_tags=""
for alias in latest-amd64 latest-arm64 latest-linux-amd64 latest-linux-arm64 "$major" latest; do
	alias_tags="$alias_tags${alias_tags:+ }$prefix$alias"
done

# Every value was checked above, so none can contain a newline.
{
	echo "versionTags=$version_tags"
	echo "aliasTags=$alias_tags"
	echo "major=$major"
} >>"$GITHUB_OUTPUT"

echo "✔ $mode run, version $VERSION"
echo "  version tags: $version_tags"
echo "  alias tags:   $alias_tags"
