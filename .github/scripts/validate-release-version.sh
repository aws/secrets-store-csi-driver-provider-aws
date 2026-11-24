#!/usr/bin/env bash
#
# Checks that VERSION can be released, before anything is built:
#   0. the run is on main
#   1. VERSION is X.Y.Z
#   2. Makefile, Chart.yaml and values.yaml all say VERSION
#   3. no git tag VERSION exists yet
#   4. VERSION is not on ECR Public yet and is higher than the newest version there
#
# Every check runs and prints one line (✔, ✘ or – skipped). If any check failed, it prints the number of
# problems and exits 1. It uses no AWS credentials: crane lists the ECR Public tags, anonymously on the CI runner.
#
# A practice run (PRACTICE=true) uses the version already on main, so it runs checks 0-2 and skips 3-4, with no
# network calls. A missing or bad PRACTICE is a wiring error: the script prints why and exits 2 before any check.
#
# Release order: 1) a bump pull request sets the new version in these three files.
# 2) The release publishes the image, then opens a pull request for deployment/aws-provider-installer.yaml.
# 3) Run release-chart.yml by hand once the image is public.
#
# Inputs (environment): VERSION, PRACTICE (true or false), GITHUB_REF.
# Test-only setting: REPO_ROOT.
# Needs yq to read Chart.yaml and values.yaml (preinstalled on GitHub's Ubuntu runners; for local runs on macOS,
# brew install yq), and crane to list the ECR Public tags (the release job installs the pinned release with
# install-crane.sh; for local runs on macOS, brew install crane).
#
# Bash 3.2 compatible (macOS /bin/bash). Bash turns off `set -e` inside functions called from `if`, `||` or `&&`,
# so every command's exit status is tested by hand. Helpers never count problems; only the checks do.

set -euo pipefail

readonly PUBLIC_REPO="public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws"
# Fixed, not $GITHUB_REPOSITORY, so a run on a fork checks the same tags as one on this repo.
readonly GITHUB_URL="https://github.com/aws/secrets-store-csi-driver-provider-aws"
readonly VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'
readonly MAX_VERSION_LENGTH=32
readonly GIT_MAX_TIME=60
readonly CRANE_MAX_TIME=60

VERSION="${VERSION:-}"
PRACTICE="${PRACTICE:-}"
GITHUB_REF="${GITHUB_REF:-}"

# No ✘ here: this is a setting, not a check, and must not look like one of the result lines.
if [[ "$PRACTICE" != true && "$PRACTICE" != false ]]; then
	echo "PRACTICE must be true or false" >&2
	exit 2
fi

problems=0
version_ok=0

ok() { echo "✔ $*"; }
fail() {
	echo "✘ $*"
	problems=$((problems + 1))
}
skip() { echo "– skipped: $*"; }

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
	lines=${lines#"$prefix"}
	lines=${lines%$'\r'}
	lines=${lines#"${lines%%[![:space:]]*}"}
	lines=${lines%"${lines##*[![:space:]]}"}
	printf '%s' "$lines"
}

readonly YAML_REFUSED="is missing, not a one-line string, or the file is not valid YAML"

# yaml_value <file> <path> : prints the string at <path>. Fails (yq -e) if it is missing, not a string, or holds a
# newline, or if the file isn't valid YAML. A block value (`tag: |`) ends in a newline that $(...) would strip, so
# the check would pass while Helm gets "3.1.5\n"; refusing newlines closes that.
yaml_value() {
	yq -e "$2 | select(tag == \"!!str\" and (test(\"\\n\") | not))" "$1"
}

# deployment/aws-provider-installer.yaml is not checked on purpose: it is served straight from main, so it is bumped
# only after the image is public.
check_repo_files() {
	local makefile="$REPO_ROOT/Makefile"
	local chart="$REPO_ROOT/charts/secrets-store-csi-driver-provider-aws/Chart.yaml"
	local values="$REPO_ROOT/charts/secrets-store-csi-driver-provider-aws/values.yaml"
	local reasons="" value key make_version=""
	local digits_re='^[0-9]+$' three_part_re='^[0-9]+\.[0-9]+\.[0-9]+$'

	if ((version_ok == 0)); then
		skip "repo files check needs a valid version"
		return
	fi
	if ! command -v yq >/dev/null 2>&1; then
		fail "yq is not installed (it reads Chart.yaml and values.yaml)"
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

	# Chart.yaml and values.yaml are read with yq, as release-chart.yml does, so both read the same values (a
	# repeated key gives the last value in both).
	if ! value=$(yaml_value "$chart" .version); then
		reasons="$reasons; Chart.yaml version $YAML_REFUSED"
	elif [[ "$value" != "$VERSION" ]]; then
		reasons="$reasons; Chart.yaml says $(printf '%q' "$value")"
	fi
	if ! value=$(yaml_value "$values" .image.repository); then
		reasons="$reasons; values.yaml image.repository $YAML_REFUSED"
	elif [[ "$value" != "$PUBLIC_REPO" ]]; then
		reasons="$reasons; values.yaml image.repository is $(printf '%q' "$value"), not $PUBLIC_REPO"
	fi
	if ! value=$(yaml_value "$values" .image.tag); then
		reasons="$reasons; values.yaml image.tag $YAML_REFUSED"
	elif [[ "$value" != "$VERSION" ]]; then
		reasons="$reasons; values.yaml image.tag says $(printf '%q' "$value")"
	fi

	if [[ -n "$reasons" ]]; then
		fail "repo files don't match $VERSION: ${reasons#; }"
	else
		ok "Makefile, Chart.yaml and values.yaml all say $VERSION"
	fi
}

check_git_tag() {
	local rc=0 out
	local -a git_args

	if ((version_ok == 0)); then
		skip "git tag check needs a valid version"
		return
	fi
	if [[ "$PRACTICE" == true ]]; then
		skip "practice run"
		return
	fi

	# The low-speed settings stop a stalled transfer; `timeout` (on the CI runner, not on macOS) also bounds
	# connect, DNS and TLS. GIT_TERMINAL_PROMPT=0 makes git fail instead of asking for a password.
	git_args=(-c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 ls-remote --exit-code --tags
		"$GITHUB_URL"
		"refs/tags/$VERSION" "refs/tags/secrets-store-csi-driver-provider-aws-$VERSION")
	if command -v timeout >/dev/null 2>&1; then
		out=$(GIT_TERMINAL_PROMPT=0 timeout "$GIT_MAX_TIME" git "${git_args[@]}" 2>&1) || rc=$?
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

# crane lists every tag; it follows the pages and retries throttled requests itself. On the CI runner there is no
# saved registry login, so the call is anonymous; locally crane uses a saved Docker login for public.ecr.aws if there
# is one. `timeout` bounds the whole call on the CI runner. macOS has no `timeout`, so a local run has no time limit.
check_registry() {
	local rc=0 tags newest

	if ((version_ok == 0)); then
		skip "ECR Public check needs a valid version"
		return
	fi
	if [[ "$PRACTICE" == true ]]; then
		skip "practice run"
		return
	fi
	if ! command -v crane >/dev/null 2>&1; then
		fail "crane is not installed (it lists the ECR Public tags)"
		return
	fi
	if command -v timeout >/dev/null 2>&1; then
		tags=$(timeout "$CRANE_MAX_TIME" crane ls "$PUBLIC_REPO") || rc=$?
	else
		tags=$(crane ls "$PUBLIC_REPO") || rc=$?
	fi
	if ((rc == 124)); then
		fail "crane ls timed out"
		return
	elif ((rc != 0)); then
		fail "could not list the tags on ECR Public (see the error above)"
		return
	fi

	newest=$(grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' <<<"$tags" | sort -V | tail -n 1 || true)
	if grep -qxF -- "$VERSION" <<<"$tags"; then
		fail "$VERSION is already on ECR Public"
	elif [[ -z "$newest" ]]; then
		fail "no X.Y.Z tags on ECR Public"
	elif [[ "$(printf '%s\n%s\n' "$newest" "$VERSION" | sort -V | tail -n 1)" != "$VERSION" ]]; then
		fail "$VERSION is not higher than the current release ($newest)"
	else
		ok "$VERSION is not on ECR Public and is higher than the current release ($newest)"
	fi
}

# --- main --------------------------------------------------------------------------------------------------------

echo "Checking release version $(printf '%q' "$VERSION") (crane: $(command -v crane || echo 'not found'))"
check_on_main
check_format
check_repo_files
check_git_tag
check_registry

suffix=""
if [[ "$PRACTICE" == true ]]; then
	suffix=" (practice)"
fi
if ((problems > 0)); then
	if ((problems == 1)); then
		echo "→ 1 problem${suffix}"
	else
		echo "→ $problems problems${suffix}"
	fi
	exit 1
fi
echo "→ all checks passed${suffix}"
