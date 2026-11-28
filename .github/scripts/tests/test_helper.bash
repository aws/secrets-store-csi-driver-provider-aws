# Shared setup for the release script tests. Loaded with `load test_helper`.
#
# Assertions are plain functions that return 1 with a message, because a failed `[[ ]]` that isn't the last
# command of a test doesn't stop the test under bash 3.2.

SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
REAL_REPO="$(cd "$SCRIPTS_DIR/../.." && pwd)"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"
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
	: >"$FAKE_DIR/crane.calls"
	: >"$FAKE_DIR/git.calls"
	: >"$FAKE_DIR/timeout.calls"
	rm -f "$FAKE_DIR/crane-tags" "$FAKE_DIR/crane-ls.exit"

	if [[ ":$PATH:" != *":$BATS_TEST_DIRNAME/fake-bin:"* ]]; then
		export PATH="$BATS_TEST_DIRNAME/fake-bin:$PATH"
	fi
	unset FAKE_TIMEOUT_EXPIRE
	export GITHUB_REF=refs/heads/main
	export PRACTICE=false

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

# --- tags for the fake crane -------------------------------------------------------------------------------------

# crane_tags <tag>... : the tags the fake crane lists. No arguments: the recorded ECR Public tags (newest 3.2.0).
crane_tags() {
	if (($# == 0)); then
		cp "$FIXTURES/ecr-public-tags.txt" "$FAKE_DIR/crane-tags"
	else
		printf '%s\n' "$@" >"$FAKE_DIR/crane-tags"
	fi
}

# crane_fails <status> : the fake crane exits with <status> instead of listing tags.
crane_fails() { echo "$1" >"$FAKE_DIR/crane-ls.exit"; }

count_lines() { wc -l <"$1" | tr -d ' '; }

# --- routes for the fake curl (registry requests) ----------------------------------------------------------------

ECR=https://ecr.test
REPO_PATH=aws-secrets-manager/secrets-store-csi-driver-provider-aws

# Call after common_setup in tests whose script talks to a registry with curl (registry-lib.sh).
registry_setup() {
	mkdir -p "$FAKE_DIR/fixtures"
	: >"$FAKE_DIR/routes"
	: >"$FAKE_DIR/curl.calls"
	export RELEASE_CHECK_ECR_URL=$ECR
	local code
	for code in 400 403 429 500 503; do
		make_reply "status-$code" "$code"
	done
}

token_url() { echo "$ECR/token/?scope=repository:$REPO_PATH:pull"; }
manifest_url() { echo "$ECR/v2/$REPO_PATH/manifests/$1"; }
tags_url() { echo "$ECR/v2/$REPO_PATH/tags/list?n=1000"; }

# route <url> <fixture>[,<fixture>...]
route() { echo "$1 $2" >>"$FAKE_DIR/routes"; }

# The URL of the recorded page 2 (from the recorded page 1's link header).
page2_url() {
	local link
	link=$(grep -i '^link:' "$FIXTURES/tags-page1.headers" | sed -E 's/^[^<]*<([^>]*)>.*$/\1/')
	echo "$ECR$link"
}

# make_reply <name> <status> [body] : a reply with a plain header block, for cases a real server can't be made
# to send on demand.
make_reply() {
	local name=$1 status=$2 body=${3:-}
	printf 'HTTP/2 %s \r\ncontent-type: application/json; charset=utf-8\r\ndocker-distribution-api-version: registry/2.0\r\n\r\n' \
		"$status" >"$FAKE_DIR/fixtures/$name.headers"
	printf '%s' "$body" >"$FAKE_DIR/fixtures/$name.body"
}

# Number of fake curl calls to one URL.
calls_to() { awk -v url="$1" '$2 == url' "$FAKE_DIR/curl.calls" | wc -l | tr -d ' '; }

# --- assertions --------------------------------------------------------------------------------------------------

expect_status() {
	if [[ "$status" != "$1" ]]; then
		printf 'expected status %s, got %s\noutput:\n%s\n' "$1" "$status" "$output"
		return 1
	fi
}

# The output has this exact line.
has_line() {
	local line
	while IFS= read -r line; do
		if [[ "$line" == "$1" ]]; then
			return 0
		fi
	done <<<"$output"
	printf 'missing line: %s\noutput:\n%s\n' "$1" "$output"
	return 1
}

# The output doesn't contain this text anywhere.
lacks_text() {
	if [[ "$output" == *"$1"* ]]; then
		printf 'unexpected text: %s\noutput:\n%s\n' "$1" "$output"
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

# expect_results <line>... : the output's result lines are exactly these, one per check (5), in order, then the
# matching "→" summary. "ok" stands for that check's usual ✔ line for $VERSION (current release 3.2.0). With
# PRACTICE=true, "ok" for checks 3-4 is the practice skip line and the summary ends in " (practice)".
expect_results() {
	local version=${VERSION:-} expected="" line i=0 failed=0 suffix=""
	local -a ok_lines=(
		"✔ on main"
		"✔ $version is a valid version"
		"✔ Makefile, Chart.yaml and values.yaml all say $version"
		"✔ no git tag $version yet"
		"✔ $version is not on ECR Public and is higher than the current release (3.2.0)"
	)
	if [[ "${PRACTICE:-}" == true ]]; then
		ok_lines[3]="– skipped: practice run"
		ok_lines[4]="– skipped: practice run"
		suffix=" (practice)"
	fi
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
	0) expected="${expected}→ all checks passed${suffix}" ;;
	1) expected="${expected}→ 1 problem${suffix}" ;;
	*) expected="${expected}→ $failed problems${suffix}" ;;
	esac
	expect_eq "$(result_lines)" "$expected"
}
