#!/usr/bin/env bats
#
# Tests for public-tags.sh (names the public version and alias tags). Pure: no fakes are called.

load test_helper

SCRIPT="$SCRIPTS_DIR/public-tags.sh"

setup() {
	common_setup
	export VERSION=3.1.5 PRACTICE=false GITHUB_RUN_ID=7
	export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	common_teardown
}

run_tags() { run bash "$SCRIPT"; }

# The value of one output key.
output_value() { sed -n "s/^$1=//p" "$GITHUB_OUTPUT"; }

# --- real runs ---------------------------------------------------------------------------------------------------

@test "a real run names the 3 version tags and the 6 aliases, latest last" {
	run_tags
	expect_status 0
	expect_eq "$(cat "$GITHUB_OUTPUT")" "versionTags=3.1.5 3.1.5-linux-amd64 3.1.5-linux-arm64
aliasTags=latest-amd64 latest-arm64 latest-linux-amd64 latest-linux-arm64 3 latest
major=3"
	has_line "✔ real run, version 3.1.5"
}

@test "the major alias is computed: 4.0.0 gives 4, 1.2.3 gives 1, 10.0.0 gives 10 (not 1)" {
	local version major
	for version in 4.0.0:4 1.2.3:1 10.0.0:10 0.9.1:0; do
		setup
		major=${version#*:}
		export VERSION=${version%:*}
		run_tags
		expect_status 0
		expect_eq "$(output_value major)" "$major"
		expect_eq "$(output_value aliasTags)" "latest-amd64 latest-arm64 latest-linux-amd64 latest-linux-arm64 $major latest"
	done
}

# --- practice runs -----------------------------------------------------------------------------------------------

@test "a practice run prefixes every tag with rehearsal-<run id>" {
	export PRACTICE=true GITHUB_RUN_ID=12345
	run_tags
	expect_status 0
	expect_eq "$(cat "$GITHUB_OUTPUT")" "versionTags=rehearsal-12345 rehearsal-12345-linux-amd64 rehearsal-12345-linux-arm64
aliasTags=rehearsal-12345-latest-amd64 rehearsal-12345-latest-arm64 rehearsal-12345-latest-linux-amd64 rehearsal-12345-latest-linux-arm64 rehearsal-12345-3 rehearsal-12345-latest
major=3"
	has_line "✔ practice run, version 3.1.5"
}

# --- refused inputs ----------------------------------------------------------------------------------------------

@test "bad versions are refused and nothing is written" {
	local version
	for version in 3.1 v3.1.5 03.1.5 3.1.5-rc1 " 3.1.5" "3.1.5
latest" 3.1.x "" "1$(printf '%033d' 0).0.0"; do
		setup
		export VERSION=$version
		run_tags
		expect_status 1
		lacks_text "✔"
		expect_eq "$(cat "$GITHUB_OUTPUT")" ""
	done
}
