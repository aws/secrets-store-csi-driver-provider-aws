#!/usr/bin/env bats
#
# Tests for validate-release-version.sh. Fake crane and timeout (fake-bin/) stand in for the real tools; the fake
# crane lists the recorded ECR Public tags (fixtures/ecr-public-tags.txt) or made-up ones. The git tag check runs
# real git on a local bare repo (fake-bin/git checks the call first), so no test touches the network. See
# test_helper.bash for the setup.

load test_helper

SCRIPT="$SCRIPTS_DIR/validate-release-version.sh"
PUBLIC_REPO=public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws

setup() {
	common_setup
	git_remote_setup
}

# The first git on PATH that isn't the fake.
real_git() {
	local dir
	local IFS=:
	for dir in $PATH; do
		if [[ "$dir" != "$BATS_TEST_DIRNAME/fake-bin" && -x "$dir/git" ]]; then
			echo "$dir/git"
			return
		fi
	done
	return 1
}

# A local bare repo stands in for the GitHub repo: the GIT_CONFIG_* settings rewrite the GitHub URL to it. It has
# one commit and no tags; tag_remote adds them.
git_remote_setup() {
	local tree
	FAKE_REAL_GIT=$(real_git)
	export FAKE_REAL_GIT GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
	export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0="url.file://$BATS_TEST_TMPDIR/remote/.insteadOf"
	export GIT_CONFIG_VALUE_0=https://github.com/
	REMOTE="$BATS_TEST_TMPDIR/remote/aws/secrets-store-csi-driver-provider-aws"
	"$FAKE_REAL_GIT" init -q --bare "$REMOTE"
	tree=$(remote_git mktree </dev/null)
	REMOTE_COMMIT=$(remote_git commit-tree -m test "$tree")
}

remote_git() {
	GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com \
		"$FAKE_REAL_GIT" --git-dir="$REMOTE" "$@"
}

# tag_remote <tag> [-a] : adds a lightweight tag (annotated with -a) to the stand-in repo.
tag_remote() {
	if [[ "${2:-}" == -a ]]; then
		remote_git tag -a -m "$1" "$1" "$REMOTE_COMMIT"
	else
		remote_git tag "$1" "$REMOTE_COMMIT"
	fi
}

teardown() {
	common_teardown
}

run_check() {
	run bash "$SCRIPT"
}

# Sets up a release of $1 that passes every check: the repo files say $1, and ECR Public has the recorded tags.
good_release() {
	export VERSION=$1
	set_version "$1"
	crane_tags
}

# --- passing -----------------------------------------------------------------------------------------------------

@test "a correct new version passes every check" {
	good_release 3.2.1
	run_check
	expect_status 0
	expect_eq "$(result_lines)" "✔ on main
✔ 3.2.1 is a valid version
✔ Makefile, Chart.yaml and values.yaml all say 3.2.1
✔ no git tag 3.2.1 yet
✔ 3.2.1 is not on ECR Public and is higher than the current release (3.2.0)
→ all checks passed"
	expect_eq "$(cat "$FAKE_DIR/crane.calls")" "ls $PUBLIC_REPO"
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
→ 1 problem"
	done
	expect_eq "$(count_lines "$FAKE_DIR/crane.calls")" 0
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
}

# --- on main -----------------------------------------------------------------------------------------------------

@test "a run that isn't on main is refused" {
	local ref
	good_release 3.2.1
	for ref in refs/heads/feature refs/heads/main-old refs/tags/main; do
		export GITHUB_REF=$ref
		run_check
		expect_status 1
		expect_results "✘ not on main (running on $ref); releases run from main only" ok ok ok ok
	done
}

# --- repo files --------------------------------------------------------------------------------------------------

@test "a Makefile version that differs is refused" {
	good_release 3.2.1
	edit_file "$(makefile)" 's/^PATCH_REV=.*/PATCH_REV=6/'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.2.1: Makefile says 3.2.6" ok ok
}

@test "a wrong value in any repo file is refused" {
	local case file expr reason
	for case in \
		"chart_yaml|s/^version:.*/version: 3.1.4/|Chart.yaml says 3.1.4" \
		"values_yaml|s/^  tag:.*/  tag: 3.1.4/|values.yaml image.tag says 3.1.4" \
		"values_yaml|s#^  repository:.*#  repository: example.com/other#|values.yaml image.repository is example.com/other, not public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws" \
		"makefile|s/^PATCH_REV=.*/PATCH_REV=5-rc1/|Makefile PATCH_REV must be bare digits, found 5-rc1" \
		"makefile|s/^PATCH_REV=.*/PATCH_REV=junk:5/|Makefile PATCH_REV must be bare digits, found junk:5"; do
		IFS='|' read -r file expr reason <<<"$case"
		common_setup
		good_release 3.2.1
		edit_file "$("$file")" "$expr"
		run_check
		expect_status 1
		expect_results ok ok "✘ repo files don't match 3.2.1: $reason" ok ok
	done
}

@test "a missing version key is refused, in each file" {
	good_release 3.2.1
	edit_file "$(makefile)" '/^MINOR_REV=/d'
	edit_file "$(chart_yaml)" '/^version:/d'
	edit_file "$(values_yaml)" '/^  tag:/d'
	run_check
	expect_status 1
	local refused="is missing, not a one-line string, or the file is not valid YAML"
	expect_results ok ok "✘ repo files don't match 3.2.1: Makefile MINOR_REV found 0 times; Chart.yaml version $refused; values.yaml image.tag $refused" ok ok
}

@test "a missing image.repository, a block value or broken YAML is refused" {
	local refused="is missing, not a one-line string, or the file is not valid YAML"
	good_release 3.2.1
	edit_file "$(values_yaml)" '/^  repository:/d'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.2.1: values.yaml image.repository $refused" ok ok

	# `version: |` reads as "3.2.1\n": $(...) would strip the newline, Helm wouldn't.
	common_setup
	good_release 3.2.1
	edit_file "$(chart_yaml)" 's/^version:.*/version: |\
  3.2.1/'
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.2.1: Chart.yaml version $refused" ok ok

	common_setup
	good_release 3.2.1
	echo 'broken: [' >>"$(values_yaml)"
	run_check
	expect_status 1
	expect_results ok ok "✘ repo files don't match 3.2.1: values.yaml image.repository $refused; values.yaml image.tag $refused" ok ok
}

@test "a missing yq is refused" {
	local tool path_dir="$BATS_TEST_TMPDIR/no-yq-bin"
	good_release 3.2.1
	mkdir -p "$path_dir"
	# The tools the script and the fakes need, without yq. Only the repo files line is checked, so a tool missing
	# from this list can't make the test pass by accident.
	for tool in awk bash cat cp dirname env git grep head sort tail tr wc; do
		ln -s "$(command -v "$tool")" "$path_dir/$tool"
	done
	PATH="$BATS_TEST_DIRNAME/fake-bin:$path_dir" run_check
	expect_status 1
	has_line "✘ yq is not installed (it reads Chart.yaml and values.yaml)"
}

# --- git tag -----------------------------------------------------------------------------------------------------

@test "git ls-remote and crane ls get the exact arguments, each wrapped in a 60 second timeout" {
	good_release 3.2.1
	run_check
	expect_status 0
	expect_eq "$(cat "$FAKE_DIR/git.calls")" "-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 ls-remote --exit-code --tags https://github.com/aws/secrets-store-csi-driver-provider-aws refs/tags/3.2.1 refs/tags/secrets-store-csi-driver-provider-aws-3.2.1"
	expect_eq "$(cat "$FAKE_DIR/timeout.calls")" "60 git $(cat "$FAKE_DIR/git.calls")
60 crane ls $PUBLIC_REPO"
}

@test "an existing git tag is refused" {
	good_release 3.2.1
	tag_remote 3.2.1
	run_check
	expect_status 1
	expect_results ok ok ok "✘ git tag 3.2.1 already exists" ok
}

@test "an existing old-style git tag is refused" {
	good_release 3.2.1
	tag_remote secrets-store-csi-driver-provider-aws-3.2.1 -a
	run_check
	expect_status 1
	expect_results ok ok ok "✘ git tag secrets-store-csi-driver-provider-aws-3.2.1 already exists" ok
}

@test "a git ls-remote error fails closed" {
	good_release 3.2.1
	export GIT_CONFIG_KEY_0="url.file://$BATS_TEST_TMPDIR/missing/.insteadOf"
	run_check
	expect_status 1
	expect_results ok ok ok "✘ git ls-remote failed (exit 128)" ok
}

@test "a git ls-remote timeout fails closed, and the ECR Public check still runs" {
	good_release 3.2.1
	export FAKE_TIMEOUT_EXPIRE=git
	run_check
	expect_status 1
	expect_results ok ok ok "✘ git ls-remote timed out" ok
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
}

# --- ECR Public --------------------------------------------------------------------------------------------------

@test "an already published version is refused" {
	good_release 3.1.2
	run_check
	expect_status 1
	expect_results ok ok ok ok "✘ 3.1.2 is already on ECR Public"
}

@test "the current release itself is refused" {
	good_release 3.2.0
	run_check
	expect_status 1
	expect_results ok ok ok ok "✘ 3.2.0 is already on ECR Public"
}

@test "a version lower than the current release is refused" {
	good_release 3.1.9
	run_check
	expect_status 1
	expect_results ok ok ok ok "✘ 3.1.9 is not higher than the current release (3.2.0)"
}

@test "versions compare numerically, not alphabetically" {
	local case new current
	for case in "3.1.10 3.1.9" "3.10.0 3.9.99" "10.0.0 9.99.99"; do
		read -r new current <<<"$case"
		common_setup
		good_release "$new"
		crane_tags 1.0.0 "$current" 3.1.2 latest
		run_check
		expect_status 0
		has_line "✔ $new is not on ECR Public and is higher than the current release ($current)"
	done

	common_setup
	good_release 3.1.9
	crane_tags 3.1.10 3.1.2
	run_check
	expect_status 1
	expect_results ok ok ok ok "✘ 3.1.9 is not higher than the current release (3.1.10)"
}

@test "no X.Y.Z tags on ECR Public is refused" {
	good_release 3.2.1
	crane_tags latest 1.0.r2-58-g4ddce6a-2024.01.31.21.42 3.1.4-linux-amd64 3
	run_check
	expect_status 1
	expect_results ok ok ok ok "✘ no X.Y.Z tags on ECR Public"
}

@test "a crane error fails closed" {
	good_release 3.2.1
	crane_fails 1
	run_check
	expect_status 1
	expect_results ok ok ok ok "✘ could not list the tags on ECR Public (see the error above)"
	has_line "Error: made-up crane failure"
}

@test "a crane ls timeout fails closed" {
	good_release 3.2.1
	export FAKE_TIMEOUT_EXPIRE=crane
	run_check
	expect_status 1
	expect_results ok ok ok ok "✘ crane ls timed out"
	expect_eq "$(count_lines "$FAKE_DIR/crane.calls")" 0
}

# --- practice runs -----------------------------------------------------------------------------------------------

@test "practice: main's own version passes, checks 3-4 are skipped, and nothing is called" {
	export PRACTICE=true VERSION=3.1.4
	set_version 3.1.4
	crane_tags # would fail the ECR Public check if it ran
	tag_remote 3.1.4 # would fail the git tag check if it ran
	run_check
	expect_status 0
	expect_eq "$(result_lines)" "✔ on main
✔ 3.1.4 is a valid version
✔ Makefile, Chart.yaml and values.yaml all say 3.1.4
– skipped: practice run
– skipped: practice run
→ all checks passed (practice)"
	expect_eq "$(count_lines "$FAKE_DIR/crane.calls")" 0
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
	expect_eq "$(count_lines "$FAKE_DIR/timeout.calls")" 0
}

@test "practice: a run off main, or with a version main doesn't have, is refused" {
	export PRACTICE=true VERSION=3.1.5 GITHUB_REF=refs/heads/feature
	set_version 3.1.4
	run_check
	expect_status 1
	expect_results "✘ not on main (running on refs/heads/feature); releases run from main only" ok \
		"✘ repo files don't match 3.1.5: Makefile says 3.1.4; Chart.yaml says 3.1.4; values.yaml image.tag says 3.1.4" \
		ok ok
	expect_eq "$(count_lines "$FAKE_DIR/crane.calls")" 0
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
}

@test "a missing or bad PRACTICE stops before any check, with no result lines" {
	local bad
	good_release 3.2.1
	for bad in "" True FALSE yes 1 "true " $'true\nfalse'; do
		export PRACTICE=$bad
		run_check
		expect_status 2
		expect_eq "$output" "PRACTICE must be true or false"
	done
	unset PRACTICE
	run_check
	expect_status 2
	expect_eq "$output" "PRACTICE must be true or false"
	expect_eq "$(count_lines "$FAKE_DIR/crane.calls")" 0
	expect_eq "$(count_lines "$FAKE_DIR/git.calls")" 0
}
