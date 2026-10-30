# Shared setup for the release script tests. Loaded with `load test_helper`.
#
# Assertions are plain functions that return 1 with a message, because a failed `[[ ]]` that isn't the last
# command of a test doesn't stop the test under bash 3.2.

SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
REAL_REPO="$(cd "$SCRIPTS_DIR/../.." && pwd)"
CHART_DIR=charts/secrets-store-csi-driver-provider-aws

# --- fakes and environment ---------------------------------------------------------------------------------------

common_setup() {
	export FAKE_DIR="$BATS_TEST_TMPDIR/fake"
	export FAKE_VIOLATIONS="$BATS_TEST_TMPDIR/violations"
	mkdir -p "$FAKE_DIR"
	# Tests that loop call this again per case; keep earlier violations so teardown still sees them.
	if [[ ! -e "$FAKE_VIOLATIONS" ]]; then
		: >"$FAKE_VIOLATIONS"
	fi
	: >"$FAKE_DIR/git.calls"
	: >"$FAKE_DIR/timeout.calls"
	echo free >"$FAKE_DIR/git.response"

	if [[ ":$PATH:" != *":$BATS_TEST_DIRNAME/fake-bin:"* ]]; then
		export PATH="$BATS_TEST_DIRNAME/fake-bin:$PATH"
	fi
	unset RELEASE_CHECK_DEADLINE_SECONDS FAKE_TIMEOUT_EXPIRE
	export GITHUB_REF=refs/heads/main
	export GITHUB_REPOSITORY=aws/secrets-store-csi-driver-provider-aws

	export REPO_ROOT="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$REPO_ROOT/$CHART_DIR"
	cp "$REAL_REPO/Makefile" "$REPO_ROOT/Makefile"
	cp "$REAL_REPO/$CHART_DIR/Chart.yaml" "$REAL_REPO/$CHART_DIR/values.yaml" "$REPO_ROOT/$CHART_DIR/"
}

# Fails the test if a fake saw a call it didn't expect.
common_teardown() {
	if [[ -s "$FAKE_VIOLATIONS" ]]; then
		echo "fake violations:"
		cat "$FAKE_VIOLATIONS"
		return 1
	fi
}

# --- repo files --------------------------------------------------------------------------------------------------

# Rewrites a file through sed (no `sed -i`: its flags differ between GNU and macOS).
edit_file() {
	local file=$1 expr=$2
	sed -E "$expr" "$file" >"$file.new"
	mv "$file.new" "$file"
}

makefile() { echo "$REPO_ROOT/Makefile"; }
chart_yaml() { echo "$REPO_ROOT/$CHART_DIR/Chart.yaml"; }
values_yaml() { echo "$REPO_ROOT/$CHART_DIR/values.yaml"; }

# Sets the version in all 3 repo files.
set_version() {
	local major minor patch
	IFS=. read -r major minor patch <<<"$1"
	edit_file "$(makefile)" "s/^MAJOR_REV=.*/MAJOR_REV=$major/; s/^MINOR_REV=.*/MINOR_REV=$minor/; s/^PATCH_REV=.*/PATCH_REV=$patch/"
	edit_file "$(chart_yaml)" "s/^version:.*/version: $1/"
	edit_file "$(values_yaml)" "s/^  tag:.*/  tag: $1/"
}

count_lines() { wc -l <"$1" | tr -d ' '; }

# --- assertions --------------------------------------------------------------------------------------------------

expect_status() {
	if [[ "$status" != "$1" ]]; then
		printf 'expected status %s, got %s\noutput:\n%s\n' "$1" "$status" "$output"
		return 1
	fi
}

expect_eq() {
	if [[ "$1" != "$2" ]]; then
		printf 'expected: %s\nactual:   %s\n' "$2" "$1"
		return 1
	fi
}

# The ✔ / ✘ / – lines of the output, in order (the header line and stderr diagnostics are dropped).
result_lines() {
	printf '%s\n' "$output" | grep -E '^(✔|✘|– skipped|→)' || true
}

# expect_results <line>... : the output's result lines are exactly these, one per check (4), in order, then the
# matching "→" summary. "ok" stands for that check's usual ✔ line for $VERSION.
expect_results() {
	local version=${VERSION:-} expected="" line i=0 failed=0
	local -a ok_lines=(
		"✔ on main"
		"✔ $version is a valid version"
		"✔ Makefile, Chart.yaml and values.yaml all say $version"
		"✔ no git tag $version yet"
	)
	if (($# != ${#ok_lines[@]})); then
		echo "expect_results needs ${#ok_lines[@]} lines, got $#"
		return 1
	fi
	for line in "$@"; do
		if [[ "$line" == ok ]]; then
			line=${ok_lines[i]}
		elif [[ "$line" == ✘* ]]; then
			failed=$((failed + 1))
		fi
		expected="$expected$line"$'\n'
		i=$((i + 1))
	done
	# ${expected} needs the braces: bash 3.2 can read the bytes of "→" as part of the variable name.
	case "$failed" in
	0) expected="${expected}→ all checks passed" ;;
	1) expected="${expected}→ 1 problem" ;;
	*) expected="${expected}→ $failed problems" ;;
	esac
	expect_eq "$(result_lines)" "$expected"
}
