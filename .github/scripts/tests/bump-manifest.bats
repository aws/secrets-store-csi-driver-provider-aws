#!/usr/bin/env bats
#
# Tests for bump-manifest.sh. The open-pr tests run real git on a local repo whose "origin" is a bare repo in the
# test's temp dir (the fake git hands -C calls to it), and the fake gh stands in for GitHub's pull request list.

load test_helper

SCRIPT="$SCRIPTS_DIR/bump-manifest.sh"
MANIFEST=deployment/aws-provider-installer.yaml
BRANCH=release/bump-manifest-3.1.5
IMAGE=public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws

setup() {
	common_setup
	export VERSION=3.1.5 PUBLIC_REPO=$IMAGE GH_TOKEN=made-up-token
	export DIGEST=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
	export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	export HOME="$BATS_TEST_TMPDIR/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
	mkdir -p "$RUNNER_TEMP" "$HOME"
	: >"$GITHUB_OUTPUT"
	: >"$FAKE_DIR/gh.calls"
	printf '[user]\n\tname = Test\n\temail = test@example.com\n[init]\n\tdefaultBranch = main\n' >"$GIT_CONFIG_GLOBAL"
	FAKE_REAL_GIT=$(real_git)
	export FAKE_REAL_GIT
	ORIGIN="$BATS_TEST_TMPDIR/origin.git"
	# The version bump that comes before a release: Makefile and chart say 3.1.5, the manifest still 3.1.4 (set
	# here, so the tests don't depend on the version the repo's manifest names today).
	set_version 3.1.5
	edit_file "$REPO_ROOT/$MANIFEST" "s|^( *image: $IMAGE):.*|\\1:3.1.4|"
}

teardown() {
	common_teardown
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

rgit() { "$FAKE_REAL_GIT" "$@"; }

# Makes REPO_ROOT a checkout of main, and ORIGIN the bare repo it was cloned from.
make_checkout() {
	rgit -C "$REPO_ROOT" init --quiet
	rgit -C "$REPO_ROOT" add -A
	rgit -C "$REPO_ROOT" commit --quiet -m main
	rgit clone --quiet --bare "$REPO_ROOT" "$ORIGIN"
	rgit -C "$REPO_ROOT" remote add origin "$ORIGIN"
}

# push_change <ref> <manifest version> [<extra file>] : a commit on origin's main that points the manifest at the
# version (and adds the file), pushed to <ref> of origin.
push_change() {
	local clone="$BATS_TEST_TMPDIR/clone-$RANDOM"
	rgit clone --quiet "$ORIGIN" "$clone"
	edit_file "$clone/$MANIFEST" "s|^( *image: $IMAGE):.*|\\1:$2|"
	if [[ -n "${3:-}" ]]; then
		echo extra >"$clone/$3"
	fi
	rgit -C "$clone" add -A
	rgit -C "$clone" commit --quiet -m change
	rgit -C "$clone" push --quiet origin "HEAD:$1"
}

# main_moves_to <version> : a later version bump lands on origin's main.
main_moves_to() {
	local clone="$BATS_TEST_TMPDIR/clone-$RANDOM"
	rgit clone --quiet "$ORIGIN" "$clone"
	edit_file "$clone/$CHART_DIR/values.yaml" "s/^  tag:.*/  tag: $1/"
	rgit -C "$clone" commit --quiet -am "version $1"
	rgit -C "$clone" push --quiet origin HEAD:main
}

# open_pr_json <number> <isCrossRepository> <head owner> <base> <file> : gh pr list's reply with one pull request.
open_pr_json() {
	printf '[{"number":%s,"url":"https://github.com/%s/secrets-store-csi-driver-provider-aws/pull/%s","isCrossRepository":%s,"headRepositoryOwner":{"login":"%s"},"baseRefName":"%s","files":[{"path":"%s","additions":1,"deletions":1}]}]' \
		"$1" "$3" "$1" "$2" "$3" "$4" "$5" >"$FAKE_DIR/gh.prs"
}

edit() { run bash "$SCRIPT" edit; }

# Runs edit (which must pass), then open-pr.
open_pr() {
	run bash "$SCRIPT" edit
	expect_status 0
	run bash "$SCRIPT" open-pr
}

# The gh calls, one per line, by their first two words.
gh_calls() { cut -d' ' -f1-2 "$FAKE_DIR/gh.calls" | tr '\n' ' '; }

# --- edit --------------------------------------------------------------------------------------------------------

@test "edit: changes only the manifest's image line, to VERSION, and writes the title and body" {
	local before="$BATS_TEST_TMPDIR/before"
	cp "$REPO_ROOT/$MANIFEST" "$before"
	edit
	expect_status 0
	has_line "✔ $MANIFEST: 3.1.4 → 3.1.5"
	expect_eq "$(diff "$before" "$REPO_ROOT/$MANIFEST" | grep '^[<>]')" "<           image: $IMAGE:3.1.4
>           image: $IMAGE:3.1.5"
	# The manifest now names the chart's version.
	grep -qxF '  tag: 3.1.5' "$REPO_ROOT/$CHART_DIR/values.yaml"
	expect_eq "$(cat "$GITHUB_OUTPUT")" "changed=true"
	expect_eq "$(cat "$RUNNER_TEMP/bump-manifest-title.txt")" "deploy: point the install manifest at 3.1.5"
	expect_eq "$(grep -o "$DIGEST" "$RUNNER_TEMP/bump-manifest-body.md" | wc -l | tr -d ' ')" 1
	grep -qF 'approve the pending workflow runs, then add the `safe-to-test` label' "$RUNNER_TEMP/bump-manifest-body.md"
}

@test "edit: a manifest already on VERSION is left alone, with changed=false" {
	edit_file "$REPO_ROOT/$MANIFEST" "s|$IMAGE:3.1.4|$IMAGE:3.1.5|"
	cp "$REPO_ROOT/$MANIFEST" "$BATS_TEST_TMPDIR/before"
	edit
	expect_status 0
	has_line "✔ $MANIFEST already points at 3.1.5; no pull request needed"
	expect_eq "$(cat "$GITHUB_OUTPUT")" "changed=false"
	cmp -s "$BATS_TEST_TMPDIR/before" "$REPO_ROOT/$MANIFEST"
}

@test "edit and open-pr: refuse a practice run before doing anything" {
	local cmd
	for cmd in edit open-pr; do
		PRACTICE=true run bash "$SCRIPT" "$cmd"
		expect_status 1
		has_line "✘ PRACTICE is true: only a real run opens the install manifest pull request"
	done
	expect_eq "$(cat "$FAKE_DIR/git.calls" "$FAKE_DIR/gh.calls")" ""
}

# --- open-pr -----------------------------------------------------------------------------------------------------

@test "open-pr: commits only the manifest as the bot, pushes the branch and opens the pull request" {
	make_checkout
	open_pr
	expect_status 0
	has_line "✔ pushed $BRANCH"
	has_line "✔ opened the pull request from $BRANCH"
	expect_eq "$(rgit -C "$ORIGIN" diff --name-only main "$BRANCH")" "$MANIFEST"
	expect_eq "$(rgit -C "$ORIGIN" rev-parse "$BRANCH~1")" "$(rgit -C "$ORIGIN" rev-parse main)"
	expect_eq "$(rgit -C "$ORIGIN" log -1 --format='%an <%ae>|%s' "$BRANCH")" \
		"github-actions[bot] <41898283+github-actions[bot]@users.noreply.github.com>|deploy: point the install manifest at 3.1.5"
	expect_eq "$(gh_calls)" "pr list auth setup-git pr create "
	expect_eq "$(tail -n 1 "$FAKE_DIR/gh.calls")" \
		"pr create --repo aws/secrets-store-csi-driver-provider-aws --base main --head $BRANCH --title deploy: point the install manifest at 3.1.5 --body-file $RUNNER_TEMP/bump-manifest-body.md"
	cmp -s "$FAKE_DIR/gh.body" "$RUNNER_TEMP/bump-manifest-body.md"
	# Every fetch names its ref.
	expect_eq "$(grep -c 'FETCH_HEAD' "$FAKE_DIR/git.calls" || true)" 0
	expect_eq "$(grep -c '^-C .* fetch ' "$FAKE_DIR/git.calls")" 2
	expect_eq "$(grep -c ' fetch --quiet origin main:refs/bump/main$' "$FAKE_DIR/git.calls")" 2
}

@test "open-pr: a re-run accepts our open pull request with the same change, and pushes nothing" {
	make_checkout
	push_change "refs/heads/$BRANCH" 3.1.5
	push_change refs/pull/7/head 3.1.5
	open_pr_json 7 false aws main "$MANIFEST"
	open_pr
	expect_status 0
	has_line "✔ https://github.com/aws/secrets-store-csi-driver-provider-aws/pull/7 is already open with this change"
	expect_eq "$(gh_calls)" "pr list "
	expect_eq "$(grep -c ' push ' "$FAKE_DIR/git.calls" || true)" 0
}

@test "open-pr: an existing branch with the same change is reused: no push, the pull request is opened" {
	make_checkout
	push_change "refs/heads/$BRANCH" 3.1.5
	open_pr
	expect_status 0
	has_line "✔ $BRANCH already has this change"
	expect_eq "$(gh_calls)" "pr list pr create "
	expect_eq "$(grep -c ' push ' "$FAKE_DIR/git.calls" || true)" 0
	grep -q " fetch --quiet origin $BRANCH:refs/bump/branch\$" "$FAKE_DIR/git.calls"
}

@test "open-pr: a pull request from a fork under the branch name is ignored with a warning" {
	make_checkout
	open_pr_json 8 true someone main "$MANIFEST"
	open_pr
	expect_status 0
	has_line "::warning::ignoring https://github.com/someone/secrets-store-csi-driver-provider-aws/pull/8: its branch $BRANCH is in a fork, not in aws/secrets-store-csi-driver-provider-aws"
	expect_eq "$(gh_calls)" "pr list auth setup-git pr create "
}

@test "open-pr: main moving on to a newer version before the pull request is opened stops the run, with no push" {
	make_checkout
	run bash "$SCRIPT" edit
	expect_status 0
	main_moves_to 3.1.6
	run bash "$SCRIPT" open-pr
	expect_status 1
	has_line "✘ charts/secrets-store-csi-driver-provider-aws/values.yaml on the latest main says image.tag 3.1.6, not 3.1.5: main has moved on to another version, so this run won't point the manifest at 3.1.5"
	lacks_text "opened the pull request"
	expect_eq "$(cat "$FAKE_DIR/gh.calls")" ""
	expect_eq "$(grep -c ' push ' "$FAKE_DIR/git.calls" || true)" 0
}
