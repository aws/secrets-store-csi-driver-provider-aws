#!/usr/bin/env bash
#
# Downloads the pinned crane release for this runner, checks its sha256, and puts crane on the PATH of the job's
# later steps (RUNNER_TEMP/bin, through GITHUB_PATH). Runs before any credentials exist.
#
# Inputs (environment, set by the runner): RUNNER_TEMP, RUNNER_ARCH (X64 or ARM64), GITHUB_PATH.
#
# Bash 3.2 compatible (macOS /bin/bash).

set -euo pipefail

# crane, pinned by version and by the sha256 of each release tarball, from the release's checksums.txt:
# https://github.com/google/go-containerregistry/releases/tag/v0.22.1
# Dependabot cannot update this: bump the version and both checksums together, by hand.
readonly CRANE_VERSION=v0.22.1
readonly CRANE_SHA256_X86_64=0ab7a1d6932a213aed964ce97666c3077fe691c8606413674a8b3e0b9ec4cda0
readonly CRANE_SHA256_ARM64=898c0cff975f898a33e8c4580bdafb0e7c02c7faa33374e946762f97c4ab7110

work_dir=""

ok() { echo "✔ $*"; }
fail() {
	echo "✘ $*"
	exit 1
}

cleanup() {
	if [[ -n "$work_dir" ]]; then
		rm -rf "$work_dir"
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

sha256_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

asset="" expected="" actual="" url="" rc=0
require RUNNER_TEMP RUNNER_ARCH GITHUB_PATH
case "$RUNNER_ARCH" in
X64)
	asset=Linux_x86_64
	expected=$CRANE_SHA256_X86_64
	;;
ARM64)
	asset=Linux_arm64
	expected=$CRANE_SHA256_ARM64
	;;
*) fail "no pinned crane for RUNNER_ARCH $(printf '%q' "$RUNNER_ARCH") (only X64 and ARM64)" ;;
esac
work_dir=$(mktemp -d "${TMPDIR:-/tmp}/install-crane.XXXXXX") || fail "could not create a temp directory"
url="https://github.com/google/go-containerregistry/releases/download/$CRANE_VERSION/go-containerregistry_$asset.tar.gz"
# --retry covers timeouts and the transient HTTP errors (408, 429, 500, 502, 503, 504). Each try stops after 60
# seconds and no retry starts after 180 seconds (even if the server asks for a longer wait), so the download ends
# within about 4 minutes, well inside the validate job's 10 minute limit.
curl --silent --show-error --fail --location --proto =https --proto-redir =https --retry 3 --max-time 60 \
	--retry-max-time 180 \
	--output "$work_dir/crane.tar.gz" "$url" || rc=$?
if ((rc != 0)); then
	fail "could not download $url (curl exit $rc)"
fi
if ! actual=$(sha256_of "$work_dir/crane.tar.gz") || [[ -z "$actual" ]]; then
	fail "could not hash the crane $CRANE_VERSION download"
fi
if [[ "$actual" != "$expected" ]]; then
	fail "the crane $CRANE_VERSION download hashes to $actual, not the pinned $expected"
fi
mkdir -p "$work_dir/extract" || fail "could not create a temp directory"
if ! tar -xzf "$work_dir/crane.tar.gz" -C "$work_dir/extract" crane; then
	fail "could not extract crane from the $CRANE_VERSION download"
fi
if [[ ! -f "$work_dir/extract/crane" || -L "$work_dir/extract/crane" ]]; then
	fail "the $CRANE_VERSION download has no regular file named crane"
fi
if ! mkdir -p "$RUNNER_TEMP/bin" || ! mv "$work_dir/extract/crane" "$RUNNER_TEMP/bin/crane" ||
	! chmod 0755 "$RUNNER_TEMP/bin/crane"; then
	fail "could not install crane into $RUNNER_TEMP/bin"
fi
printf '%s\n' "$RUNNER_TEMP/bin" >>"$GITHUB_PATH"
ok "installed crane $CRANE_VERSION ($asset, sha256 $expected) into $RUNNER_TEMP/bin"
