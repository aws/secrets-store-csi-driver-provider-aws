#!/usr/bin/env bash
#
# Checks that VERSION can be released, before anything is built:
#   0. the run is on main
#   1. VERSION is X.Y.Z
#   2. Makefile, Chart.yaml and values.yaml all say VERSION
#   3. no git tag VERSION exists yet
#
# Every check runs and prints one line (✔, ✘ or – skipped). If any check failed, it prints the number of
# problems and exits 1.
#
# Inputs (environment): VERSION, GITHUB_REF, GITHUB_REPOSITORY.
# Test-only settings: REPO_ROOT, RELEASE_CHECK_DEADLINE_SECONDS.
#
# Bash 3.2 compatible (macOS /bin/bash). Bash turns off `set -e` inside functions called from `if`, `||` or `&&`,
# so every command's exit status is tested by hand. Helpers never count problems; only the checks do.

set -euo pipefail

readonly PUBLIC_REPO="public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws"
readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly MAX_VERSION_LENGTH=32
readonly GIT_MAX_TIME=60
readonly TIME_FLOOR=5      # never start a network call with less than this many seconds left

VERSION="${VERSION:-}"
GITHUB_REF="${GITHUB_REF:-}"
GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-}"
DEADLINE="${RELEASE_CHECK_DEADLINE_SECONDS:-360}"

if [[ ! "$DEADLINE" =~ ^[0-9]+$ ]]; then
	echo "✘ DEADLINE must be a whole number of seconds" >&2
	exit 1
fi

problems=0
version_ok=0

ok() { echo "✔ $*"; }
fail() {
	echo "✘ $*"
	problems=$((problems + 1))
}
skip() { echo "– skipped: $*"; }

seconds_left() { echo $((DEADLINE - SECONDS)); }

# --- temp files --------------------------------------------------------------------------------------------------

work_dir=$(mktemp -d "${TMPDIR:-/tmp}/release-check.XXXXXX") || {
	echo "✘ could not create a temp directory"
	exit 1
}
cleanup() { rm -rf "$work_dir"; }
trap cleanup EXIT
trap 'cleanup; exit 129' HUP
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# --- repo root ---------------------------------------------------------------------------------------------------

if [[ -z "${REPO_ROOT:-}" ]]; then
	REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
fi

# --- checks ------------------------------------------------------------------------------------------------------

check_on_main() {
	if [[ -z "$GITHUB_REF" ]]; then
		fail "GITHUB_REF is not set"
	elif [[ "$GITHUB_REF" != "refs/heads/main" ]]; then
		fail "not on main (running on $GITHUB_REF); releases run from main only"
	else
		ok "on main"
	fi
}

check_format() {
	local version_re=$VERSION_RE
	if [[ -z "$VERSION" ]]; then
		fail "VERSION is not set"
	elif ((${#VERSION} > MAX_VERSION_LENGTH)); then
		fail "version is longer than $MAX_VERSION_LENGTH characters"
	elif [[ ! "$VERSION" =~ $version_re ]]; then
		fail "$(printf '%q' "$VERSION") is not a valid version: use X.Y.Z, e.g. 3.1.5 (no \"v\", no suffix, no leading zeros)"
	else
		version_ok=1
		ok "$VERSION is a valid version"
	fi
}

# Removes one pair of matching surrounding quotes, as YAML does.
unquote() {
	local value=$1
	local double_re='^"(.*)"$' single_re="^'(.*)'$"
	if [[ "$value" =~ $double_re ]] || [[ "$value" =~ $single_re ]]; then
		value=${BASH_REMATCH[1]}
	fi
	printf '%s' "$value"
}

# Prints the value of the single line matching "^<prefix>" in a file. Fails if there are 0 or 2+ such lines.
# Trailing spaces and \r are removed.
single_value() {
	local file=$1 prefix=$2 lines count
	lines=$(grep -E "^$prefix" "$file" || true)
	count=0
	if [[ -n "$lines" ]]; then
		count=$(printf '%s\n' "$lines" | wc -l | tr -d ' ')
	fi
	if [[ "$count" != 1 ]]; then
		echo "found $count times"
		return 1
	fi
	lines=${lines#*:}
	if [[ "$prefix" == *= ]]; then
		lines=${lines#*=}
	fi
	lines=${lines%$'\r'}
	lines=${lines#"${lines%%[![:space:]]*}"}
	lines=${lines%"${lines##*[![:space:]]}"}
	printf '%s' "$lines"
}

# deployment/aws-provider-installer.yaml is not checked on purpose: it is served straight from main, so it is bumped
# only after the image is public.
check_repo_files() {
	local makefile="$REPO_ROOT/Makefile"
	local chart="$REPO_ROOT/charts/secrets-store-csi-driver-provider-aws/Chart.yaml"
	local values="$REPO_ROOT/charts/secrets-store-csi-driver-provider-aws/values.yaml"
	local reasons="" value key make_version="" part image_block image_count
	local digits_re='^[0-9]+$' three_part_re='^[0-9]+\.[0-9]+\.[0-9]+$'

	if ((version_ok == 0)); then
		skip "repo files check needs a valid version"
		return
	fi
	for file in "$makefile" "$chart" "$values"; do
		if [[ ! -r "$file" ]]; then
			fail "cannot read ${file#"$REPO_ROOT"/}"
			return
		fi
	done

	# Makefile: Make keeps quotes as part of a value, so only bare digits are accepted.
	for key in MAJOR_REV MINOR_REV PATCH_REV; do
		if ! value=$(single_value "$makefile" "$key="); then
			reasons="$reasons; Makefile $key $value"
			continue
		fi
		if [[ ! "$value" =~ $digits_re ]]; then
			reasons="$reasons; Makefile $key must be bare digits, found $(printf '%q' "$value")"
			continue
		fi
		make_version="$make_version${make_version:+.}$value"
	done
	if [[ "$make_version" =~ $three_part_re && "$make_version" != "$VERSION" ]]; then
		reasons="$reasons; Makefile says $make_version"
	fi

	if ! value=$(single_value "$chart" "version:"); then
		reasons="$reasons; Chart.yaml version $value"
	else
		value=$(unquote "$value")
		if [[ "$value" != "$VERSION" ]]; then
			reasons="$reasons; Chart.yaml says $(printf '%q' "$value")"
		fi
	fi

	# values.yaml: the top-level image: block, then its 2-space-indented repository: and tag:.
	image_count=$(grep -cE '^image:[[:space:]]*$' "$values" || true)
	if [[ "$image_count" != 1 ]]; then
		reasons="$reasons; values.yaml image: block found $image_count times"
	else
		image_block="$work_dir/image-block"
		if ! awk '/^image:[[:space:]]*$/ { inside = 1; next } inside && /^[^[:space:]#]/ { inside = 0 } inside' \
			"$values" >"$image_block"; then
			fail "could not read the image: block in values.yaml"
			return
		fi
		for part in repository tag; do
			if ! value=$(single_value "$image_block" "  $part:"); then
				reasons="$reasons; values.yaml image.$part $value"
				continue
			fi
			value=$(unquote "$value")
			if [[ "$part" == repository && "$value" != "$PUBLIC_REPO" ]]; then
				reasons="$reasons; values.yaml image.repository is $(printf '%q' "$value"), not $PUBLIC_REPO"
			elif [[ "$part" == tag && "$value" != "$VERSION" ]]; then
				reasons="$reasons; values.yaml image.tag says $(printf '%q' "$value")"
			fi
		done
	fi

	if [[ -n "$reasons" ]]; then
		fail "repo files don't match $VERSION: ${reasons#; }"
	else
		ok "Makefile, Chart.yaml and values.yaml all say $VERSION"
	fi
}

check_git_tag() {
	local repo_re='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' left limit rc=0 out
	local -a git_args

	if ((version_ok == 0)); then
		skip "git tag check needs a valid version"
		return
	fi
	if [[ -z "$GITHUB_REPOSITORY" ]]; then
		fail "GITHUB_REPOSITORY is not set"
		return
	fi
	if [[ ! "$GITHUB_REPOSITORY" =~ $repo_re ]]; then
		fail "GITHUB_REPOSITORY $(printf '%q' "$GITHUB_REPOSITORY") is not owner/name"
		return
	fi
	left=$(seconds_left)
	if ((left < TIME_FLOOR)); then
		fail "ran out of time while checking git tags"
		return
	fi

	# The low-speed settings stop a stalled transfer; `timeout` (on the CI runner, not on macOS) also bounds
	# connect, DNS and TLS. GIT_TERMINAL_PROMPT=0 makes git fail instead of asking for a password.
	git_args=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 ls-remote --exit-code --tags
		"https://github.com/$GITHUB_REPOSITORY"
		"refs/tags/$VERSION" "refs/tags/secrets-store-csi-driver-provider-aws-$VERSION")
	if command -v timeout >/dev/null 2>&1; then
		limit=$GIT_MAX_TIME
		if ((left < limit)); then
			limit=$left
		fi
		out=$(GIT_TERMINAL_PROMPT=0 timeout "$limit" git "${git_args[@]}" 2>&1) || rc=$?
	else
		out=$(GIT_TERMINAL_PROMPT=0 git "${git_args[@]}" 2>&1) || rc=$?
	fi

	case "$rc" in
	2) ok "no git tag $VERSION yet" ;;
	0)
		if [[ "$out" == *"refs/tags/secrets-store-csi-driver-provider-aws-$VERSION"* ]]; then
			fail "git tag secrets-store-csi-driver-provider-aws-$VERSION already exists"
		else
			fail "git tag $VERSION already exists"
		fi
		;;
	124) fail "git ls-remote timed out" ;;
	*)
		echo "$out" | head -5 >&2 || true # head may close the pipe early; that must not stop the script
		fail "git ls-remote failed (exit $rc)"
		;;
	esac
}

# --- main --------------------------------------------------------------------------------------------------------

echo "Checking release version $(printf '%q' "$VERSION")"
check_on_main
check_format
check_repo_files
check_git_tag

if ((problems > 0)); then
	if ((problems == 1)); then
		echo "→ 1 problem"
	else
		echo "→ $problems problems"
	fi
	exit 1
fi
echo "→ all checks passed"
