# Shared setup for the release script tests. Loaded with `load test_helper`.
#
# Assertions are plain functions that return 1 with a message, because a failed `[[ ]]` that isn't the last
# command of a test doesn't stop the test under bash 3.2.

SCRIPTS_DIR="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
REAL_REPO="$(cd "$SCRIPTS_DIR/../.." && pwd)"
FIXTURES="$BATS_TEST_DIRNAME/fixtures"
ECR=https://ecr.test
REPO_PATH=aws-secrets-manager/secrets-store-csi-driver-provider-aws
CHART_DIR=charts/secrets-store-csi-driver-provider-aws

# --- fakes and environment ---------------------------------------------------------------------------------------

common_setup() {
	export FAKE_DIR="$BATS_TEST_TMPDIR/fake"
	export FAKE_VIOLATIONS="$BATS_TEST_TMPDIR/violations"
	mkdir -p "$FAKE_DIR/fixtures"
	# Tests that loop call this again per case; keep earlier violations so teardown still sees them.
	if [[ ! -e "$FAKE_VIOLATIONS" ]]; then
		: >"$FAKE_VIOLATIONS"
	fi
	: >"$FAKE_DIR/routes"
	: >"$FAKE_DIR/curl.calls"
	: >"$FAKE_DIR/git.calls"
	: >"$FAKE_DIR/timeout.calls"
	echo free >"$FAKE_DIR/git.response"

	if [[ ":$PATH:" != *":$BATS_TEST_DIRNAME/fake-bin:"* ]]; then
		export PATH="$BATS_TEST_DIRNAME/fake-bin:$PATH"
	fi
	export RELEASE_CHECK_ECR_URL=$ECR
	export RELEASE_CHECK_RETRY_SCALE=0
	unset RELEASE_CHECK_DEADLINE_SECONDS FAKE_TIMEOUT_EXPIRE
	export GITHUB_REF=refs/heads/main
	export GITHUB_REPOSITORY=aws/secrets-store-csi-driver-provider-aws
	export PRACTICE=false

	export REPO_ROOT="$BATS_TEST_TMPDIR/repo"
	mkdir -p "$REPO_ROOT/$CHART_DIR"
	cp "$REAL_REPO/Makefile" "$REPO_ROOT/Makefile"
	cp "$REAL_REPO/$CHART_DIR/Chart.yaml" "$REAL_REPO/$CHART_DIR/values.yaml" "$REPO_ROOT/$CHART_DIR/"

	make_made_up_replies
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

# --- routes for the fake curl ------------------------------------------------------------------------------------

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

# Token OK, VERSION not published, the recorded 2 tag pages (newest release 3.1.4).
default_routes() {
	route "$(token_url)" token
	route "$(manifest_url "$1")" manifest-404
	route "$(tags_url)" tags-page1
	route "$(page2_url)" tags-page2
}

# tags_fixture <name> <link path or ""> <tag>... : a 200 tag-list reply, optionally with a next-page link.
tags_fixture() {
	local name=$1 link=$2 json="" tag
	shift 2
	{
		printf 'HTTP/2 200 \r\ncontent-type: text/plain; charset=utf-8\r\ndocker-distribution-api-version: registry/2.0\r\n'
		if [[ -n "$link" ]]; then
			printf 'link: <%s>; rel="next"\r\n' "$link"
		fi
		printf '\r\n'
	} >"$FAKE_DIR/fixtures/$name.headers"
	for tag in "$@"; do
		json="$json${json:+,}\"$tag\""
	done
	printf '{"name":"%s","tags":[%s]}' "$REPO_PATH" "$json" >"$FAKE_DIR/fixtures/$name.body"
}

# make_reply <name> <status> [body] : a reply with a plain header block, for cases a real server can't be made
# to send on demand.
make_reply() {
	local name=$1 status=$2 body=${3:-}
	printf 'HTTP/2 %s \r\ncontent-type: application/json; charset=utf-8\r\ndocker-distribution-api-version: registry/2.0\r\n\r\n' \
		"$status" >"$FAKE_DIR/fixtures/$name.headers"
	printf '%s' "$body" >"$FAKE_DIR/fixtures/$name.body"
}

# The made-up replies the tests use by name. Only real recorded replies are saved in fixtures/.
make_made_up_replies() {
	local code
	for code in 400 403 429 500 503; do
		make_reply "status-$code" "$code"
	done
	make_reply not-json 200 '<html>not json</html>'
	make_reply token-missing 200 '{}'
	make_reply token-empty 200 '{"token":""}'
	tags_fixture tags-empty ""
	tags_fixture tags-no-release "" latest 1.0.r2-58-g4ddce6a-2024.01.31.21.42 3.1.4-linux-amd64
	# A newer version that's only on page 2 (page 1 is the recorded one, which links here).
	tags_fixture tags-page2-newer "" 3.1.1 3.2.0 3.0.1
	# The recorded page 1, with the header name written "Link:" (HTTP/1.1 servers may capitalize it).
	sed 's/^link:/Link:/' "$FIXTURES/tags-page1.headers" >"$FAKE_DIR/fixtures/tags-page1-capital-link.headers"
	cp "$FIXTURES/tags-page1.body" "$FAKE_DIR/fixtures/tags-page1-capital-link.body"
}

# A tag-list reply whose link header is given verbatim (for malformed links).
raw_link_fixture() {
	local name=$1 header=$2
	{
		printf 'HTTP/2 200 \r\ncontent-type: text/plain; charset=utf-8\r\n%s\r\n\r\n' "$header"
	} >"$FAKE_DIR/fixtures/$name.headers"
	printf '{"name":"%s","tags":["3.1.4"]}' "$REPO_PATH" >"$FAKE_DIR/fixtures/$name.body"
}

# Number of fake curl calls to one URL.
calls_to() { awk -v url="$1" '$2 == url' "$FAKE_DIR/curl.calls" | wc -l | tr -d ' '; }
count_lines() { wc -l <"$1" | tr -d ' '; }

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

# expect_results <line>... : the output's result lines are exactly these, one per check (6), in order, then the
# matching "→" summary. "ok" stands for that check's usual ✔ line for $VERSION (current release 3.1.4). With
# PRACTICE=true, "ok" for checks 3-5 is the practice skip line and the summary ends in " (practice)".
expect_results() {
	local version=${VERSION:-} expected="" line i=0 failed=0 suffix=""
	local -a ok_lines=(
		"✔ on main"
		"✔ $version is a valid version"
		"✔ Makefile, Chart.yaml and values.yaml all say $version"
		"✔ no git tag $version yet"
		"✔ $version is not on ECR Public yet"
		"✔ $version is higher than the current release (3.1.4)"
	)
	if [[ "${PRACTICE:-}" == true ]]; then
		ok_lines[3]="– skipped: practice run"
		ok_lines[4]="– skipped: practice run"
		ok_lines[5]="– skipped: practice run"
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

# The skipped lines that follow a refused version.
NO_VERSION_SKIPS=(
	"– skipped: repo files check needs a valid version"
	"– skipped: git tag check needs a valid version"
	"– skipped: ECR Public check needs a valid version"
	"– skipped: version order check needs a valid version"
)
