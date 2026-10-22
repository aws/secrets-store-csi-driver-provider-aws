#!/usr/bin/env bash
#
# The Release workflow's last job, real runs only: a pull request that points the raw install manifest,
# deployment/aws-provider-installer.yaml, at the version just published. The Makefile and the chart already name
# the version (validate-release-version.sh requires it); the manifest waits because it is served straight from main.
#
#   edit     checks main's chart still names VERSION, points the manifest's image line at it, writes the title and
#            body to RUNNER_TEMP, and changed=true|false (false: the line already says VERSION) to $GITHUB_OUTPUT
#   open-pr  commits the edit on release/bump-manifest-VERSION, pushes it and opens the pull request. A re-run
#            accepts the branch or an open pull request from this repo only if it holds the same one-file change.
#            It never force-pushes and never merges.
#
# Environment: PUBLIC_REPO (must be the production repo), PRACTICE (must be false), VERSION, RUNNER_TEMP; edit also
# DIGEST and GITHUB_OUTPUT; open-pr also GITHUB_REPOSITORY and GH_TOKEN. Run from a checkout of main with full
# history and an "origin" remote. Test-only setting: REPO_ROOT.
#
# Every fetch writes a named refs/bump/* ref, never FETCH_HEAD, so a later fetch can't change what an earlier
# comparison read. Bash 3.2: `set -e` is off inside functions called from `if`, `||` or `&&`, so every exit status
# is tested by hand.

set -euo pipefail

# shellcheck source-path=SCRIPTDIR source=registry-lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"

readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly DIGEST_RE='^sha256:[0-9a-f]{64}$'
readonly MANIFEST=deployment/aws-provider-installer.yaml
readonly VALUES=charts/secrets-store-csi-driver-provider-aws/values.yaml
readonly IMAGE_LINE_RE='^[[:space:]]*image: public\.ecr\.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws:[^[:space:]]*$'
readonly BOT_NAME='github-actions[bot]'
readonly BOT_EMAIL='41898283+github-actions[bot]@users.noreply.github.com'

# git must fail rather than wait for a password.
export GIT_TERMINAL_PROMPT=0

ok() { echo "✔ $*"; }
fail() {
	echo "✘ $*"
	exit 1
}

require() {
	local name
	for name in "$@"; do
		if [[ -z "${!name:-}" ]]; then
			fail "$name is not set"
		fi
	done
}

# The inputs both commands share. check_target refuses anything but the production repo when PRACTICE is false.
check_inputs() {
	require VERSION RUNNER_TEMP
	if [[ "${PRACTICE:-}" != false ]]; then
		fail "PRACTICE is $(printf '%q' "${PRACTICE:-}"): only a real run opens the install manifest pull request"
	fi
	check_target || exit 1
	if [[ ! "$VERSION" =~ $VERSION_RE ]]; then
		fail "$(printf '%q' "$VERSION") is not a valid version (X.Y.Z)"
	fi
	if [[ -z "${REPO_ROOT:-}" ]]; then
		REPO_ROOT=$(git rev-parse --show-toplevel) || fail "not in a git checkout"
	fi
	title_file="$RUNNER_TEMP/bump-manifest-title.txt"
	body_file="$RUNNER_TEMP/bump-manifest-body.md"
	branch="release/bump-manifest-$VERSION"
}

repo_git() { git -C "$REPO_ROOT" "$@"; }

# Prints the image.tag of a values.yaml read on stdin: the one 2-space-indented tag: line of the top-level image:
# block, quotes removed. Returns 1 if there isn't exactly one.
values_tag() {
	local tags
	tags=$(awk '/^image:[[:space:]]*$/ { inside = 1; next } inside && /^[^[:space:]#]/ { inside = 0 }
		inside && /^  tag:/ { sub(/^  tag:[[:space:]]*/, ""); sub(/[[:space:]]+$/, ""); gsub(/^["'\'']|["'\'']$/, ""); print }') ||
		return 1
	if [[ -z "$tags" || "$tags" == *$'\n'* ]]; then
		return 1
	fi
	printf '%s\n' "$tags"
}

# check_main_version <where> : the values.yaml read on stdin still names VERSION. If main names another version,
# this pull request would point the manifest back at an older image.
check_main_version() {
	local tag
	tag=$(values_tag) || fail "could not read image.tag from $VALUES on $1"
	if [[ "$tag" != "$VERSION" ]]; then
		fail "$VALUES on $1 says image.tag $(printf '%q' "$tag"), not $VERSION: main has moved on to another version, so this run won't point the manifest at $VERSION"
	fi
	ok "$1 still names $VERSION in $VALUES"
}

# --- edit --------------------------------------------------------------------------------------------------------

cmd_edit() {
	local file count old_line before after changed
	check_inputs
	require DIGEST GITHUB_OUTPUT
	if [[ ! "$DIGEST" =~ $DIGEST_RE ]]; then
		fail "DIGEST $(printf '%q' "$DIGEST") is not sha256:<64 lowercase hex>"
	fi
	if [[ ! -r "$REPO_ROOT/$VALUES" || ! -r "$REPO_ROOT/$MANIFEST" ]]; then
		fail "cannot read $VALUES and $MANIFEST"
	fi
	check_main_version main <"$REPO_ROOT/$VALUES"

	file="$REPO_ROOT/$MANIFEST"
	count=$(grep -cE "$IMAGE_LINE_RE" "$file" || true)
	if [[ "$count" != 1 ]]; then
		fail "$MANIFEST has $count image lines for the public repo, expected 1"
	fi
	old_line=$(grep -E "$IMAGE_LINE_RE" "$file")
	if [[ "$old_line" == *":$VERSION" ]]; then
		ok "$MANIFEST already points at $VERSION; no pull request needed"
		echo "changed=false" >>"$GITHUB_OUTPUT"
		return
	fi

	# Written to a new file and moved over the old one (no `sed -i`: its flags differ between GNU and macOS).
	sed -E 's|^([[:space:]]*image: public\.ecr\.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws):[^[:space:]]*$|\1:'"$VERSION"'|' \
		"$file" >"$file.new" || fail "could not edit $MANIFEST"
	before=$(wc -l <"$file")
	after=$(wc -l <"$file.new")
	changed=$( (diff "$file" "$file.new" || true) | grep -c '^[<>]' || true)
	if [[ "$before" != "$after" || "$changed" != 2 ]]; then
		rm -f "$file.new"
		fail "the edit of $MANIFEST did not change exactly one line"
	fi
	mv "$file.new" "$file" || fail "could not write $MANIFEST"
	ok "$MANIFEST: ${old_line##*:} → $VERSION"

	echo "deploy: point the install manifest at $VERSION" >"$title_file"
	cat >"$body_file" <<EOF
Points \`$MANIFEST\` at $VERSION. The Release workflow published $VERSION to ECR Public as \`$DIGEST\`, then checked every version and alias tag anonymously.

Checks: approve the pending workflow runs, then add the \`safe-to-test\` label.
EOF
	echo "changed=true" >>"$GITHUB_OUTPUT"
}

# --- open-pr -----------------------------------------------------------------------------------------------------

# Fetches main into refs/bump/main, then checks it still names VERSION.
fetch_main() {
	repo_git fetch --quiet origin "main:refs/bump/main" || fail "could not fetch main"
	repo_git show "refs/bump/main:$VALUES" | check_main_version "the latest main"
}

# same_change <ref> : since it left main, <ref> changes only MANIFEST, and changes it the way our commit does.
same_change() {
	local base files change
	base=$(repo_git merge-base refs/bump/main "$1") || return 1
	files=$(repo_git diff --name-only "$base" "$1") || return 1
	change=$(repo_git diff "$base" "$1" -- "$MANIFEST") || return 1
	[[ "$files" == "$MANIFEST" && "$change" == "$our_change" ]]
}

# Checks each open pull request from the bump branch. Fork pull requests are skipped with a warning (this run
# pushes only to this repo). One from this repo is accepted only if it targets main, changes only MANIFEST,
# and makes our change. Sets accepted_url.
check_open_prs() {
	local list kind number url base files
	accepted_url=""
	list=$(gh pr list --repo "$GITHUB_REPOSITORY" --head "$branch" --state open \
		--json number,url,isCrossRepository,headRepositoryOwner,baseRefName,files) ||
		fail "could not list the open pull requests from $branch"
	# One line per pull request: fork|same, number, url, base branch, one-file|other-files.
	list=$(printf '%s' "$list" | python3 -I -c '
import json, re, sys
owner, path = sys.argv[1], sys.argv[2]
prs = json.load(sys.stdin)
if type(prs) is not list:
    sys.exit("not a list of pull requests")
for pr in prs:
    number, url, cross = pr["number"], pr["url"], pr["isCrossRepository"]
    base, files = pr["baseRefName"], [f["path"] for f in pr["files"] or []]
    head_owner = (pr["headRepositoryOwner"] or {}).get("login")
    if (type(number) is not int or type(cross) is not bool or not re.match(r"^https://\S+$", url)
            or not re.match(r"^\S+$", base)):
        sys.exit("unexpected pull request fields")
    kind = "fork" if cross or head_owner != owner else "same"
    print(kind, number, url, base, "one-file" if files == [path] else "other-files", sep="\t")
' "${GITHUB_REPOSITORY%%/*}" "$MANIFEST") || fail "could not read the open pull requests from $branch"

	while IFS=$'\t' read -r kind number url base files; do
		if [[ -z "$kind" ]]; then
			continue
		fi
		if [[ "$kind" == fork ]]; then
			echo "::warning::ignoring $url: its branch $branch is in a fork, not in $GITHUB_REPOSITORY"
			continue
		fi
		if [[ "$base" != main || "$files" != one-file ]]; then
			fail "$url is open from $branch but does not change only $MANIFEST on main; check it, then re-run"
		fi
		repo_git fetch --quiet origin "pull/$number/head:refs/bump/pr" || fail "could not fetch $url"
		if ! same_change refs/bump/pr; then
			fail "$url is open from $branch but its change is not this run's change; check it, then re-run"
		fi
		accepted_url=${accepted_url:-$url}
	done <<<"$list"
}

cmd_open_pr() {
	local file status base ls_status
	check_inputs
	require GITHUB_REPOSITORY GH_TOKEN
	for file in "$title_file" "$body_file"; do
		[[ -s "$file" ]] || fail "${file##*/} is missing: run the edit command first"
	done

	status=$(repo_git status --porcelain) || fail "could not read the checkout's status"
	if [[ "$status" != " M $MANIFEST" ]]; then
		fail "the checkout should change only $MANIFEST, but has: $status"
	fi
	repo_git checkout --quiet -b "$branch" || fail "could not create the branch $branch"
	repo_git add -- "$MANIFEST" || fail "could not stage $MANIFEST"
	repo_git -c "user.name=$BOT_NAME" -c "user.email=$BOT_EMAIL" commit --quiet \
		-m "deploy: point the install manifest at $VERSION" || fail "could not commit $MANIFEST"
	fetch_main
	base=$(repo_git merge-base refs/bump/main HEAD) || fail "the checkout has no common history with main"
	our_change=$(repo_git diff "$base" HEAD -- "$MANIFEST") || fail "could not diff the commit"

	check_open_prs
	if [[ -n "$accepted_url" ]]; then
		fetch_main
		ok "$accepted_url is already open with this change"
		return
	fi

	ls_status=0
	repo_git ls-remote --quiet --exit-code origin "refs/heads/$branch" >/dev/null || ls_status=$?
	case "$ls_status" in
	2)
		gh auth setup-git || fail "could not set up git to push with the workflow token"
		repo_git push --quiet origin "HEAD:refs/heads/$branch" || fail "could not push $branch"
		ok "pushed $branch"
		;;
	0)
		repo_git fetch --quiet origin "$branch:refs/bump/branch" || fail "could not fetch $branch"
		if ! same_change refs/bump/branch; then
			fail "$branch already exists with another change; this run never force-pushes, so check it, then re-run"
		fi
		ok "$branch already has this change"
		;;
	*) fail "could not read whether $branch exists (git ls-remote exit $ls_status)" ;;
	esac

	fetch_main
	gh pr create --repo "$GITHUB_REPOSITORY" --base main --head "$branch" --title "$(cat "$title_file")" \
		--body-file "$body_file" || fail "could not open the pull request"
	ok "opened the pull request from $branch"
}

# --- main --------------------------------------------------------------------------------------------------------

case "${1:-}" in
edit) cmd_edit ;;
open-pr) cmd_open_pr ;;
*)
	echo "usage: $0 edit | open-pr" >&2
	exit 2
	;;
esac
