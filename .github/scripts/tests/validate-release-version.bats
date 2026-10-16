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

@test "every curl call gets --max-time 15 when plenty of time is left" {
	good_release 3.1.5
	run_check
	expect_status 0
	expect_eq "$(count_lines "$FAKE_DIR/curl.calls")" 4
	expect_eq "$(awk '$1 != 15' "$FAKE_DIR/curl.calls")" ""
}

@test "quoted YAML values pass" {
	good_release 3.1.5
	edit_file "$(values_yaml)" 's/^  tag:.*/  tag: "3.1.5"/'
	edit_file "$(chart_yaml)" "s/^version:.*/version: '3.1.5'/"
	run_check
	expect_status 0
	has_line "✔ Makefile, Chart.yaml and values.yaml all say 3.1.5"
}

@test "the output names the curl it used" {
	good_release 3.1.5
	run_check
	has_line "Checking release version 3.1.5 (curl: $BATS_TEST_DIRNAME/fake-bin/curl)"
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

@test "an empty version is refused" {
	export VERSION=""
	run_check
	expect_status 1
	expect_results ok "✘ VERSION is not set" "${NO_VERSION_SKIPS[@]}"
}

@test "an unset version is refused, not a crash" {
	unset VERSION
	run_check
	expect_status 1
	expect_results ok "✘ VERSION is not set" "${NO_VERSION_SKIPS[@]}"
}

@test "a version longer than 32 characters is refused" {
	export VERSION=1.1.111111111111111111111111111111
	run_check
	expect_status 1
	expect_results ok "✘ version is longer than 32 characters" "${NO_VERSION_SKIPS[@]}"
}

# --- on main -----------------------------------------------------------------------------------------------------

@test "a run that isn't on main is refused" {
	good_release 3.1.5
	export GITHUB_REF=refs/heads/feature
	run_check
	expect_status 1
	expect_results "✘ not on main (running on refs/heads/feature); releases run from main only" ok ok ok ok ok
}

@test "an unset GITHUB_REF is a failed check, not a crash" {
	good_release 3.1.5
	unset GITHUB_REF
	run_check
	expect_status 1
	expect_results "✘ GITHUB_REF is not set" ok ok ok ok ok
}

# --- repo files --------------------------------------------------------------------------------------------------

@test "a Makefile version that differs is refused" {
	good_release 3.1.5
	edit_file "$(makefile)" 's/^PATCH_REV=.*/PATCH_REV=6/'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: Makefile says 3.1.6" ok ok ok
}

@test "a Chart.yaml version that differs is refused" {
	good_release 3.1.5
	edit_file "$(chart_yaml)" 's/^version:.*/version: 3.1.4/'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: Chart.yaml says 3.1.4" ok ok ok
}

@test "a values.yaml tag that differs is refused" {
	good_release 3.1.5
	edit_file "$(values_yaml)" 's/^  tag:.*/  tag: 3.1.4/'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: values.yaml image.tag says 3.1.4" ok ok ok
}

@test "a wrong values.yaml repository is refused" {
	good_release 3.1.5
	edit_file "$(values_yaml)" 's#^  repository:.*#  repository: public.ecr.aws/someone/else#'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: values.yaml image.repository is public.ecr.aws/someone/else, not public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws" ok ok ok
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

@test "a duplicated version key is refused, in each file" {
	good_release 3.1.5
	edit_file "$(makefile)" 's/^(PATCH_REV=.*)$/\1\
PATCH_REV=5/'
	edit_file "$(chart_yaml)" 's/^(version:.*)$/\1\
version: 3.1.5/'
	edit_file "$(values_yaml)" 's/^(  tag:.*)$/\1\
  tag: 3.1.5/'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: Makefile PATCH_REV found 2 times; Chart.yaml version found 2 times; values.yaml image.tag found 2 times" ok ok ok
}

@test "a missing or duplicated values.yaml image block is refused" {
	good_release 3.1.5
	edit_file "$(values_yaml)" 's/^image:/picture:/'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: values.yaml image: block found 0 times" ok ok ok

	printf 'image:\n  tag: 3.1.5\n' >>"$(values_yaml)"
	edit_file "$(values_yaml)" 's/^picture:/image:/'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: values.yaml image: block found 2 times" ok ok ok
}

@test "a missing or duplicated image.repository is refused" {
	good_release 3.1.5
	edit_file "$(values_yaml)" '/^  repository:/d'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: values.yaml image.repository found 0 times" ok ok ok

	cp "$REAL_REPO/$CHART_DIR/values.yaml" "$(values_yaml)"
	set_version 3.1.5
	edit_file "$(values_yaml)" 's#^(  repository:.*)$#\1\
  repository: public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws#'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.1.5: values.yaml image.repository found 2 times" ok ok ok
}

@test "a quoted Makefile value is refused (Make keeps the quotes)" {
	good_release 3.1.5
	edit_file "$(makefile)" 's/^MAJOR_REV=.*/MAJOR_REV="3"/'
	run_check
	expect_status 1
	expect_results ok ok '✘ repo files don'"'"'t match 3.1.5: Makefile MAJOR_REV must be bare digits, found \"3\"' ok ok ok
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

@test "an existing old-style git tag is refused" {
	good_release 3.1.5
	echo taken-old >"$FAKE_DIR/git.response"
	run_check
	expect_status 1
	expect_results ok ok ok "✘ git tag secrets-store-csi-driver-provider-aws-3.1.5 already exists" ok ok
}

@test "a git ls-remote error fails closed" {
	good_release 3.1.5
	echo exit:128 >"$FAKE_DIR/git.response"
	run_check
	expect_status 1
	expect_results ok ok ok "✘ git ls-remote failed (exit 128)" ok ok
}

@test "a git ls-remote timeout fails closed, and the ECR checks still run" {
	good_release 3.1.5
	export FAKE_TIMEOUT_EXPIRE=1
	run_check
	expect_status 1
	expect_results ok ok ok "✘ git ls-remote timed out" ok ok
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
}

@test "an unset GITHUB_REPOSITORY is a failed check, not a crash" {
	good_release 3.1.5
	unset GITHUB_REPOSITORY
	run_check
	expect_status 1
	expect_results ok ok ok "✘ GITHUB_REPOSITORY is not set" ok ok
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
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

@test "3.1.4 lists all 3 problems (git tag, published, not higher)" {
	export VERSION=3.1.4
	echo taken >"$FAKE_DIR/git.response"
	route "$(token_url)" token
	route "$(manifest_url 3.1.4)" manifest-200
	route "$(tags_url)" tags-page1
	route "$(page2_url)" tags-page2
	run_check
	expect_status 1
	expect_eq "$(result_lines)" "✔ on main
✔ 3.1.4 is a valid version
✔ Makefile, Chart.yaml and values.yaml all say 3.1.4
✘ git tag 3.1.4 already exists
✘ 3.1.4 is already on ECR Public
✘ 3.1.4 is not higher than the current release (3.1.4)
→ 3 problems"
}

# --- ECR Public: higher than current -----------------------------------------------------------------------------

@test "a version lower than the current release is refused" {
	good_release 3.1.3
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ 3.1.3 is not higher than the current release (3.1.4)"
}

@test "a version equal to the current release fails only the 'higher' check" {
	good_release 3.1.4
	run_check
	expect_status 1
	expect_eq "$(result_lines)" "✔ on main
✔ 3.1.4 is a valid version
✔ Makefile, Chart.yaml and values.yaml all say 3.1.4
✔ no git tag 3.1.4 yet
✔ 3.1.4 is not on ECR Public yet
✘ 3.1.4 is not higher than the current release (3.1.4)
→ 1 problem"
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

@test "a capitalized Link header is followed too" {
	good_release 3.1.5
	: >"$FAKE_DIR/routes"
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-404
	route "$(tags_url)" tags-page1-capital-link
	route "$(page2_url)" tags-page2-newer
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ 3.1.5 is not higher than the current release (3.2.0)"
}

@test "a single page with no link header passes" {
	good_release 3.1.5
	: >"$FAKE_DIR/routes"
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-404
	route "$(tags_url)" tags-page2
	run_check
	expect_status 0
	has_line "✔ 3.1.5 is higher than the current release (3.1.2)"
}

@test "the recorded header fixtures still end lines in \\r\\n" {
	grep -q $'\r$' "$FIXTURES/tags-page1.headers"
	grep -q $'\r$' "$FIXTURES/manifest-404.headers"
}

@test "the capital-Link page really has a capitalized header and the same link" {
	grep -q '^Link: <' "$FAKE_DIR/fixtures/tags-page1-capital-link.headers"
	expect_eq "$(grep -ci '^link:' "$FAKE_DIR/fixtures/tags-page1-capital-link.headers")" 1
	expect_eq "$(grep -c '^link:' "$FAKE_DIR/fixtures/tags-page1-capital-link.headers" || true)" 0
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

@test "429, 500 or 503 once, then success, passes" {
	local code
	for code in 429 500 503; do
		common_setup
		manifest_answers "status-$code,manifest-404"
		run_check
		expect_status 0
		has_line "✔ 3.1.5 is not on ECR Public yet"
		expect_eq "$(calls_to "$(manifest_url 3.1.5)")" 2
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

@test "a tag list that isn't JSON fails closed" {
	good_release 3.1.5
	: >"$FAKE_DIR/routes"
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-404
	route "$(tags_url)" not-json
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ could not check the current release (tag list is not valid JSON)"
}

@test "an empty tag list, or one with no X.Y.Z tags, fails closed" {
	local fixture
	for fixture in tags-empty tags-no-release; do
		common_setup
		good_release 3.1.5
		: >"$FAKE_DIR/routes"
		route "$(token_url)" token
		route "$(manifest_url 3.1.5)" manifest-404
		route "$(tags_url)" "$fixture"
		run_check
		expect_status 1
		expect_results ok ok ok ok ok "✘ could not check the current release (no X.Y.Z tags on ECR Public)"
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

@test "two link headers fail closed" {
	good_release 3.1.5
	: >"$FAKE_DIR/routes"
	raw_link_fixture twolinks "link: </v2/$REPO_PATH/tags/list?last=a>; rel=\"next\""$'\r\n'"Link: </v2/$REPO_PATH/tags/list?last=b>; rel=\"next\""
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-404
	route "$(tags_url)" twolinks
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ could not check the current release (more than one link header)"
}

@test "a page link loop fails closed" {
	good_release 3.1.5
	: >"$FAKE_DIR/routes"
	local loop="/v2/$REPO_PATH/tags/list?last=loop&n=1000"
	tags_fixture first "$loop" 3.1.4
	tags_fixture again "$loop" 3.1.3
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-404
	route "$(tags_url)" first
	route "$ECR$loop" again
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ could not check the current release (page link loop)"
	expect_eq "$(calls_to "$ECR$loop")" 1
}

@test "a page link back to page 1 fails closed without fetching page 1 again" {
	good_release 3.1.5
	: >"$FAKE_DIR/routes"
	tags_fixture first "/v2/$REPO_PATH/tags/list?last=2&n=1000" 3.1.4
	tags_fixture back "/v2/$REPO_PATH/tags/list?n=1000" 3.1.3
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-404
	route "$(tags_url)" first
	route "$ECR/v2/$REPO_PATH/tags/list?last=2&n=1000" back
	run_check
	expect_status 1
	expect_results ok ok ok ok ok "✘ could not check the current release (page link loop)"
	expect_eq "$(calls_to "$(tags_url)")" 1
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

@test "several problems at once are all listed" {
	export VERSION=3.1.5
	export GITHUB_REF=refs/heads/other
	set_version 3.1.6
	echo taken >"$FAKE_DIR/git.response"
	route "$(token_url)" token
	route "$(manifest_url 3.1.5)" manifest-200
	route "$(tags_url)" tags-page1
	route "$(page2_url)" tags-page2
	run_check
	expect_status 1
	expect_eq "$(result_lines)" "✘ not on main (running on refs/heads/other); releases run from main only
✔ 3.1.5 is a valid version
✘ repo files don't match 3.1.5: Makefile says 3.1.6; Chart.yaml says 3.1.6; values.yaml image.tag says 3.1.6
✘ git tag 3.1.5 already exists
✘ 3.1.5 is already on ECR Public
✔ 3.1.5 is higher than the current release (3.1.4)
→ 4 problems"
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

# --- live smoke test (by hand only: LIVE=1 bats .github/scripts/tests) --------------------------------------------

@test "live: 3.1.4 against the real registry and GitHub lists the 3 expected problems" {
	if [[ "${LIVE:-0}" != 1 ]]; then
		skip "set LIVE=1 to run against the real ECR Public and GitHub"
	fi
	export PATH="${PATH#"$BATS_TEST_DIRNAME/fake-bin:"}"
	unset RELEASE_CHECK_ECR_URL
	export VERSION=3.1.4 RELEASE_CHECK_RETRY_SCALE=1
	cp "$REAL_REPO/Makefile" "$(makefile)"
	set_version 3.1.4
	run_check
	expect_status 1
	has_line "✘ git tag 3.1.4 already exists"
	has_line "✘ 3.1.4 is already on ECR Public"
	has_line "✘ 3.1.4 is not higher than the current release (3.1.4)"
	has_line "→ 3 problems"
}
