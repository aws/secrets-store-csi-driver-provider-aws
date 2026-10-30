#!/usr/bin/env bats
#
# Tests for validate-release-version.sh. Fake git and timeout (fake-bin/) replay recorded responses
# (fixtures/), so no test touches the network. See test_helper.bash for the setup.

load test_helper

SCRIPT="$SCRIPTS_DIR/validate-release-version.sh"

setup() {
	common_setup
}

teardown() {
	common_teardown
}

run_check() {
	run bash "$SCRIPT"
}

# Sets up a release of $1 that passes every check.
good_release() {
	export VERSION=$1
	set_version "$1"
}

# --- passing -----------------------------------------------------------------------------------------------------

@test "a correct new version passes every check" {
	good_release 3.1.5
	run_check
	expect_status 0
	expect_eq "$(result_lines)" "✔ on main
✔ 3.1.5 is a valid version
✔ Makefile, Chart.yaml and values.yaml all say 3.1.5
✔ no git tag 3.1.5 yet
→ all checks passed"
}

# --- format ------------------------------------------------------------------------------------------------------

@test "a bad version format is refused and the checks that need it are skipped" {
	local bad
	for bad in v3.1.5 3.1 3.1.5-rc1 03.1.5 3.01.5 3.1.05 "3.1.5 " 3..5; do
		export VERSION=$bad
		run_check
		expect_status 1
		expect_eq "$(result_lines)" "✔ on main
✘ $(printf '%q' "$bad") is not a valid version: use X.Y.Z, e.g. 3.1.5 (no \"v\", no suffix, no leading zeros)
– skipped: repo files check needs a valid version
– skipped: git tag check needs a valid version
→ 1 problem"
	done
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
}

# --- on main -----------------------------------------------------------------------------------------------------

@test "a run that isn't on main is refused" {
	good_release 3.1.5
	export GITHUB_REF=refs/heads/feature
	run_check
	expect_status 1
	expect_results "✘ not on main (running on refs/heads/feature); releases run from main only" ok ok ok
}

# --- repo files --------------------------------------------------------------------------------------------------

@test "a Makefile version that differs is refused" {
	good_release 3.1.5
	edit_file "$(makefile)" 's/^PATCH_REV=.*/PATCH_REV=6/'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: Makefile says 3.1.6" ok
}

@test "a missing version key is refused, in each file" {
	good_release 3.1.5
	edit_file "$(makefile)" '/^MINOR_REV=/d'
	edit_file "$(chart_yaml)" '/^version:/d'
	edit_file "$(values_yaml)" '/^  tag:/d'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: Makefile MINOR_REV found 0 times; Chart.yaml version found 0 times; values.yaml image.tag found 0 times" ok
}

# --- git tag -----------------------------------------------------------------------------------------------------

@test "git ls-remote gets the exact arguments, wrapped in timeout" {
	good_release 3.1.5
	run_check
	expect_status 0
	expect_eq "$(cat "$FAKE_DIR/git.calls")" "-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 ls-remote --exit-code --tags https://github.com/aws/secrets-store-csi-driver-provider-aws refs/tags/3.1.5 refs/tags/secrets-store-csi-driver-provider-aws-3.1.5"
	local seconds
	seconds=$(awk '{ print $1 }' "$FAKE_DIR/timeout.calls")
	expect_eq "$(count_lines "$FAKE_DIR/timeout.calls")" 1
	expect_eq "$(cut -d' ' -f2- "$FAKE_DIR/timeout.calls")" "git $(cat "$FAKE_DIR/git.calls")"
	if ((seconds < 1 || seconds > 60)); then
		echo "timeout seconds $seconds outside 1..60"
		return 1
	fi
}

@test "an existing git tag is refused" {
	good_release 3.1.5
	echo taken >"$FAKE_DIR/git.response"
	run_check
	expect_status 1
	expect_results ok ok ok "✘ git tag 3.1.5 already exists"
}

@test "a git ls-remote error fails closed" {
	good_release 3.1.5
	echo exit:128 >"$FAKE_DIR/git.response"
	run_check
	expect_status 1
	expect_results ok ok ok "✘ git ls-remote failed (exit 128)"
}

# --- fail closed -------------------------------------------------------------------------------------------------

@test "the deadline stops before any network call and still prints the summary" {
	good_release 3.1.5
	export RELEASE_CHECK_DEADLINE_SECONDS=0
	run_check
	expect_status 1
	expect_eq "$(result_lines)" "✔ on main
✔ 3.1.5 is a valid version
✔ Makefile, Chart.yaml and values.yaml all say 3.1.5
✘ ran out of time while checking git tags
→ 1 problem"
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
	expect_eq "$(count_lines "$FAKE_DIR/timeout.calls")" 0
}

@test "the temp directory is removed after the run" {
	good_release 3.1.5
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$TMPDIR"
	run_check
	expect_status 0
	expect_eq "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0
}
