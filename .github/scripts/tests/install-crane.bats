#!/usr/bin/env bats
#
# Tests for install-crane.sh. The fake curl (fake-bin/) serves made-up downloads, so no test touches the network
# except the live one, which runs only with LIVE=1. See test_helper.bash for the setup.

load test_helper

SCRIPT="$SCRIPTS_DIR/install-crane.sh"
CRANE_X86_64_URL=https://github.com/google/go-containerregistry/releases/download/v0.22.1/go-containerregistry_Linux_x86_64.tar.gz
CRANE_ARM64_URL=https://github.com/google/go-containerregistry/releases/download/v0.22.1/go-containerregistry_Linux_arm64.tar.gz

setup() {
	common_setup
	mkdir -p "$FAKE_DIR/fixtures"
	: >"$FAKE_DIR/routes"
	: >"$FAKE_DIR/curl.calls"
	export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp" TMPDIR="$BATS_TEST_TMPDIR/tmp"
	export GITHUB_PATH="$BATS_TEST_TMPDIR/github_path" RUNNER_ARCH=X64
	mkdir -p "$RUNNER_TEMP" "$TMPDIR"
	: >"$GITHUB_PATH"
}

teardown() {
	common_teardown
}

install_crane() {
	run bash "$SCRIPT"
}

# route <url> <fixture>[,<fixture>...]
route() { echo "$1 $2" >>"$FAKE_DIR/routes"; }

digest_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

has_text() {
	if [[ "$output" != *"$1"* ]]; then
		printf 'missing text: %s\noutput:\n%s\n' "$1" "$output"
		return 1
	fi
}

# Nothing was installed and the temp directory was removed.
expect_not_installed() {
	expect_eq "$(cat "$GITHUB_PATH")" ""
	if [[ -e "$RUNNER_TEMP/bin/crane" ]]; then
		echo "crane was installed"
		return 1
	fi
	expect_eq "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0
}

# pinned_copy <tarball> : a copy of the script whose x86_64 pin is <tarball>'s sha256, so the install path can run
# on a made-up release. Only the copy changes; the real pin has no override.
pinned_copy() {
	local copy="$BATS_TEST_TMPDIR/pinned-scripts"
	mkdir -p "$copy"
	cp "$SCRIPT" "$copy/"
	edit_file "$copy/install-crane.sh" "s/^readonly CRANE_SHA256_X86_64=.*/readonly CRANE_SHA256_X86_64=$(digest_of "$1")/"
	grep -qxF "readonly CRANE_SHA256_X86_64=$(digest_of "$1")" "$copy/install-crane.sh"
	SCRIPT="$copy/install-crane.sh"
}

@test "a download that doesn't match the pinned sha256 is refused and nothing is installed" {
	local arch url pin_name pin
	for arch in X64:X86_64:$CRANE_X86_64_URL ARM64:ARM64:$CRANE_ARM64_URL; do
		setup
		export RUNNER_ARCH=${arch%%:*}
		pin_name=${arch#*:}
		pin_name=${pin_name%%:*}
		url=${arch#*:*:}
		# Each arch must be checked against its own pin, so a swapped pin fails here.
		pin=$(sed -n "s/^readonly CRANE_SHA256_$pin_name=//p" "$SCRIPT")
		[[ "$pin" =~ ^[0-9a-f]{64}$ ]] || false
		printf 'not the crane release' >"$FAKE_DIR/fixtures/tampered.download"
		route "$url" tampered
		install_crane
		expect_status 1
		has_line "✘ the crane v0.22.1 download hashes to $(digest_of "$FAKE_DIR/fixtures/tampered.download"), not the pinned $pin"
		expect_eq "$(cat "$FAKE_DIR/curl.calls")" "60 $url"
		expect_not_installed
	done
}

@test "a failed download fails" {
	local reply
	for reply in neterror http404; do
		setup
		route "$CRANE_X86_64_URL" "$reply"
		install_crane
		expect_status 1
		has_line "✘ could not download $CRANE_X86_64_URL (curl exit $([[ $reply == neterror ]] && echo 6 || echo 22))"
		expect_not_installed
	done
}

@test "an unknown runner arch fails before any download" {
	local arch
	for arch in X86 ARM x64; do
		setup
		export RUNNER_ARCH=$arch
		install_crane
		expect_status 1
		has_line "✘ no pinned crane for RUNNER_ARCH $arch (only X64 and ARM64)"
		expect_eq "$(count_lines "$FAKE_DIR/curl.calls")" 0
	done
	setup
	export RUNNER_ARCH=""
	install_crane
	expect_status 1
	has_line "✘ RUNNER_ARCH is not set"
	expect_eq "$(count_lines "$FAKE_DIR/curl.calls")" 0
}

@test "a release that matches the pin is extracted into RUNNER_TEMP/bin and put on the PATH" {
	mkdir -p "$BATS_TEST_TMPDIR/release"
	printf '#!/bin/sh\necho fake crane\n' >"$BATS_TEST_TMPDIR/release/crane"
	tar -czf "$FAKE_DIR/fixtures/release.download" -C "$BATS_TEST_TMPDIR/release" crane
	pinned_copy "$FAKE_DIR/fixtures/release.download"
	route "$CRANE_X86_64_URL" release
	install_crane
	expect_status 0
	has_line "✔ installed crane v0.22.1 (Linux_x86_64, sha256 $(digest_of "$FAKE_DIR/fixtures/release.download")) into $RUNNER_TEMP/bin"
	expect_eq "$(cat "$GITHUB_PATH")" "$RUNNER_TEMP/bin"
	expect_eq "$("$RUNNER_TEMP/bin/crane")" "fake crane"
	expect_eq "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0
}

@test "a release with no crane file is refused" {
	mkdir -p "$BATS_TEST_TMPDIR/release"
	printf 'not crane\n' >"$BATS_TEST_TMPDIR/release/README"
	tar -czf "$FAKE_DIR/fixtures/release.download" -C "$BATS_TEST_TMPDIR/release" README
	pinned_copy "$FAKE_DIR/fixtures/release.download"
	route "$CRANE_X86_64_URL" release
	install_crane
	expect_status 1
	has_line "✘ could not extract crane from the v0.22.1 download"
	expect_not_installed
}

# By hand only: LIVE=1 bats .github/scripts/tests
@test "live: downloads the pinned release for both arches and installs it" {
	if [[ "${LIVE:-0}" != 1 ]]; then
		skip "set LIVE=1 to download the real crane release"
	fi
	local arch
	for arch in X64 ARM64; do
		setup
		export PATH="${PATH#"$BATS_TEST_DIRNAME/fake-bin:"}" RUNNER_ARCH=$arch
		install_crane
		expect_status 0
		has_text "✔ installed crane v0.22.1 "
		expect_eq "$(cat "$GITHUB_PATH")" "$RUNNER_TEMP/bin"
		if [[ ! -f "$RUNNER_TEMP/bin/crane" || ! -x "$RUNNER_TEMP/bin/crane" ]]; then
			echo "crane is not installed as an executable file"
			return 1
		fi
		expect_eq "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0
	done
}
