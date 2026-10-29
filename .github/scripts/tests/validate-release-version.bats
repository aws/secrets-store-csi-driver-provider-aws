#!/usr/bin/env bats
#
# Tests for validate-release-version.sh. Fake curl, git and timeout (fake-bin/) replay recorded responses
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
	default_routes "$1"
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
✔ 3.1.5 is not on ECR Public yet
✔ 3.1.5 is higher than the current release (3.1.4)
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
– skipped: ECR Public check needs a valid version
– skipped: version order check needs a valid version
→ 1 problem"
	done
	expect_eq "$(count_lines "$FAKE_DIR/curl.calls")" 0
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
}

# --- on main -----------------------------------------------------------------------------------------------------

@test "a run that isn't on main is refused" {
	good_release 3.1.5
	export GITHUB_REF=refs/heads/feature
	run_check
	expect_status 1
	expect_results "✘ not on main (running on refs/heads/feature); releases run from main only" ok ok ok ok ok
}

# --- repo files --------------------------------------------------------------------------------------------------

@test "a Makefile version that differs is refused" {
	good_release 3.1.5
	edit_file "$(makefile)" 's/^PATCH_REV=.*/PATCH_REV=6/'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: Makefile says 3.1.6" ok ok ok
}

@test "a missing version key is refused, in each file" {
	good_release 3.1.5
	edit_file "$(makefile)" '/^MINOR_REV=/d'
	edit_file "$(chart_yaml)" '/^version:/d'
	edit_file "$(values_yaml)" '/^  tag:/d'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: Makefile MINOR_REV found 0 times; Chart.yaml version found 0 times; values.yaml image.tag found 0 times" ok ok ok
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
	expect_results ok ok ok "✘ git tag 3.1.5 already exists" ok ok
}

@test "a git ls-remote error fails closed" {
	good_release 3.1.5
	echo exit:128 >"$FAKE_DIR/git.response"
	run_check
	expect_status 1
	expect_results ok ok ok "✘ git ls-remote failed (exit 128)" ok ok
}

# --- ECR Public: already published ------------------------------------------------------------------------------

@test "an already published version is refused" {
	export VERSION=3.1.5
	set_version 3.1.5
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-200
	route "$(tags_url)" tags-page1
	route "$(page2_url)" tags-page2
	run_check
	expect_status 1
	expect_results ok ok ok ok "✘ 3.1.5 is already on ECR Public" ok
}

# --- ECR Public: higher than current -----------------------------------------------------------------------------

@test "a version lower than the current release is refused" {
	good_release 3.1.3
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ 3.1.3 is not higher than the current release (3.1.4)"
}

@test "versions compare numerically, not alphabetically" {
	local case new current
	for case in "3.1.10 3.1.9" "3.10.0 3.9.99" "10.0.0 9.99.99"; do
		read -r new current <<<"$case"
		common_setup
		good_release "$new"
		: >"$FAKE_DIR/routes"
		tags_fixture single "" 1.0.0 "$current" 3.1.2 latest
		route "$(token_url)" token
		route "$(manifest_url "$new")" manifest-404
		route "$(tags_url)" single
		run_check
		expect_status 0
		has_line "✔ $new is higher than the current release ($current)"
	done

	common_setup
	good_release 3.1.9
	: >"$FAKE_DIR/routes"
	tags_fixture single "" 3.1.10 3.1.2
	route "$(token_url)" token
	route "$(manifest_url 3.1.9)" manifest-404
	route "$(tags_url)" single
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ 3.1.9 is not higher than the current release (3.1.10)"
}

# --- pagination --------------------------------------------------------------------------------------------------

@test "a newer version only on page 2 is found" {
	good_release 3.1.5
	: >"$FAKE_DIR/routes"
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-404
	route "$(tags_url)" tags-page1
	route "$(page2_url)" tags-page2-newer
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ 3.1.5 is not higher than the current release (3.2.0)"
	expect_eq "$(calls_to "$(page2_url)")" 1
}

# --- fail closed -------------------------------------------------------------------------------------------------

# Routes the manifest request to the given fixtures; everything else is normal.
manifest_answers() {
	good_release 3.1.5
	: >"$FAKE_DIR/routes"
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" "$1"
	route "$(tags_url)" tags-page1
	route "$(page2_url)" tags-page2
}

@test "a curl network error fails closed" {
	manifest_answers neterror
	run_check
	expect_status 1
	expect_results ok ok ok ok "✘ could not check ECR Public (see the error above)" ok
}

@test "HTTP 400, 401 and 403 fail closed at once" {
	local code
	for code in 400 401 403; do
		common_setup
		manifest_answers "status-$code"
		run_check
		expect_status 1
		expect_results ok ok ok ok "✘ could not check ECR Public (HTTP $code)" ok
		expect_eq "$(calls_to "$(manifest_url 3.1.5)")" 1
	done
}

@test "429 and 500 that never clear fail closed after exactly 5 attempts" {
	local code
	for code in 429 500; do
		common_setup
		manifest_answers "status-$code"
		run_check
		expect_status 1
		expect_results ok ok ok ok "✘ could not check ECR Public (see the error above)" ok
		expect_eq "$(calls_to "$(manifest_url 3.1.5)")" 5
	done
}

@test "a bad, missing or empty token fails closed, and isn't asked for twice" {
	local fixture
	for fixture in not-json token-missing token-empty status-401; do
		common_setup
		good_release 3.1.5
		: >"$FAKE_DIR/routes"
		route "$(token_url)" "$fixture"
		run_check
		expect_status 1
		expect_results ok ok ok ok "✘ could not check ECR Public (see the error above)" \
			"✘ could not check the current release (see the error above)"
		expect_eq "$(calls_to "$(token_url)")" 1
	done
}

# Page 1 has the given link header; nothing else is routed, so following it would be a fake violation.
bad_link() {
	common_setup
	good_release 3.1.5
	: >"$FAKE_DIR/routes"
	raw_link_fixture badlink "$1"
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-404
	route "$(tags_url)" badlink
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ could not check the current release (unexpected page link)"
}

@test "page links to another host, absolute URLs and malformed links fail closed" {
	bad_link "link: <https://evil.example/v2/$REPO_PATH/tags/list?last=x>; rel=\"next\""
	bad_link "link: <$ECR/v2/$REPO_PATH/tags/list?last=x>; rel=\"next\""
	bad_link "link: <//evil.example/v2/$REPO_PATH/tags/list?last=x>; rel=\"next\""
	bad_link "link: </v2/other/repo/tags/list?last=x>; rel=\"next\""
	bad_link "link: </v2/$REPO_PATH/tags/list?last=x; rel=\"next\""
	bad_link "link: </v2/$REPO_PATH/tags/list?last=x>; rel=\"prev\""
	bad_link "link: </v2/$REPO_PATH/tags/list?last=[x]>; rel=\"next\""
}

@test "more than 5 pages fails closed" {
	good_release 3.1.5
	: >"$FAKE_DIR/routes"
	local page
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-404
	tags_fixture page1 "/v2/$REPO_PATH/tags/list?last=2&n=1000" 3.1.4
	route "$(tags_url)" page1
	for page in 2 3 4 5 6; do
		tags_fixture "page$page" "/v2/$REPO_PATH/tags/list?last=$((page + 1))&n=1000" 3.1.4
		route "$ECR/v2/$REPO_PATH/tags/list?last=$page&n=1000" "page$page"
	done
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ tag list has more than 5 pages"
	expect_eq "$(calls_to "$ECR/v2/$REPO_PATH/tags/list?last=6&n=1000")" 0
}

@test "the deadline stops before any network call and still prints the summary" {
	good_release 3.1.5
	export RELEASE_CHECK_DEADLINE_SECONDS=0
	run_check
	expect_status 1
	expect_eq "$(result_lines)" "✔ on main
✔ 3.1.5 is a valid version
✔ Makefile, Chart.yaml and values.yaml all say 3.1.5
✘ ran out of time while checking git tags
– skipped: ran out of time
– skipped: ran out of time
→ 1 problem"
	expect_eq "$(count_lines "$FAKE_DIR/curl.calls")" 0
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
	expect_eq "$(count_lines "$FAKE_DIR/timeout.calls")" 0
}

@test "the token is never printed" {
	good_release 3.1.5
	run_check
	lacks_text "fake-token"
	manifest_answers status-403
	run_check
	lacks_text "fake-token"
}

@test "the temp directory is removed after the run" {
	good_release 3.1.5
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$TMPDIR"
	run_check
	expect_status 0
	expect_eq "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0
}
