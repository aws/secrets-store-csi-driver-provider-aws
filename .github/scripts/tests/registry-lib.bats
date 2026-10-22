#!/usr/bin/env bats
#
# Tests for registry-lib.sh (the helpers and checks the release scripts source). Each test sources the library into
# a fresh bash with fatal-free ok/fail printers and calls one function. The fake curl (fake-bin/) replays recorded
# replies, so no test touches a registry.

load test_helper

LIB="$SCRIPTS_DIR/registry-lib.sh"
PROD=public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws
SANDBOX_PATH=example-sandbox/secrets-store-csi-driver-provider-aws

setup() {
	common_setup
	export REGISTRY_URL=$ECR REGISTRY_RETRY_SCALE=0 REGISTRY_PACE_SECONDS=0 REGISTRY_DEADLINE=300
	export REGISTRY_REPO_PATH=$REPO_PATH
	export REGISTRY_WORK_DIR="$BATS_TEST_TMPDIR/work"
	mkdir -p "$REGISTRY_WORK_DIR"
	unset PUBLIC_REPO
	# The recorded public 3.1.4 index without its 2 attestation entries (as staging-image.bats makes it).
	GOOD_INDEX="$BATS_TEST_TMPDIR/good-index.json"
	jq -c '.manifests |= map(select(.platform.os != "unknown"))' "$FIXTURES/index-public-3.1.4.json" |
		tr -d '\n' >"$GOOD_INDEX"
}

teardown() {
	common_teardown
}

# lib <function> [args]... : sources the library and calls one function, then prints "rc=<status>".
lib() {
	run bash -c '
		set -euo pipefail
		ok() { echo "✔ $*"; }
		fail() { echo "✘ $*"; }
		source "$1"
		shift
		rc=0
		"$@" || rc=$?
		echo "rc=$rc"
	' lib "$LIB" "$@"
}

@test "it is shared: staging-image.sh, publish-image.sh and verify-public-image.sh source it" {
	grep -qxF 'source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"' "$SCRIPTS_DIR/staging-image.sh"
	grep -qxF 'source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"' "$SCRIPTS_DIR/publish-image.sh"
	grep -qxF 'source "$(dirname "${BASH_SOURCE[0]}")/registry-lib.sh"' "$SCRIPTS_DIR/verify-public-image.sh"
}

# --- check_target ------------------------------------------------------------------------------------------------

@test "check_target: a real run must target the production repo" {
	PUBLIC_REPO=$PROD PRACTICE=false lib check_target
	has_line "✔ target $PROD (real run, the production repo)"
	has_line "rc=0"

	PUBLIC_REPO=public.ecr.aws/$SANDBOX_PATH PRACTICE=false lib check_target
	has_line "✘ a real run must publish to $PROD, not public.ecr.aws/$SANDBOX_PATH"
	has_line "rc=1"
}

@test "check_target: a practice run must not target the production repo" {
	PUBLIC_REPO=$PROD PRACTICE=true lib check_target
	has_line "✘ a practice run must not publish to the production repo $PROD"
	has_line "rc=1"
	lacks_text "✔"

	PUBLIC_REPO=public.ecr.aws/$SANDBOX_PATH PRACTICE=true lib check_target
	has_line "✔ target public.ecr.aws/$SANDBOX_PATH (practice run, not the production repo)"
	has_line "rc=0"
}

@test "check_target: repo look-alikes are refused in both modes" {
	local repo practice
	for practice in true false; do
		for repo in "$PROD/" "$PROD:3.1.4" "https://$PROD" "public.ecr.aws/Aws-Secrets-Manager/x" \
			"public.ecr.aws/a/b/c" "public.ecr.aws/a" "public.ecr.aws.evil.example/a/b" "ghcr.io/a/b" \
			"public.ecr.aws/a-/b" "public.ecr.aws/a/b
" " $PROD" "public.ecr.aws/a/$(printf 'b%.0s' $(seq 1 260))"; do
			PUBLIC_REPO=$repo PRACTICE=$practice lib check_target
			has_line "rc=1"
			lacks_text "✔"
		done
	done
}

# --- check_platforms ---------------------------------------------------------------------------------------------

# platforms <name> <jq filter on the good index> : writes that index and runs check_platforms on it.
platforms() {
	jq -c "$2" "$GOOD_INDEX" >"$BATS_TEST_TMPDIR/$1.json"
	lib check_platforms "$BATS_TEST_TMPDIR/$1.json" the-index
}

@test "check_platforms: amd64 + arm64 passes, as does arm64/v8" {
	platforms good .
	has_line "✔ platforms: linux/amd64 linux/arm64"
	has_line "rc=0"
	platforms v8 '(.manifests[] | select(.platform.architecture == "arm64") | .platform.variant) = "v8"'
	has_line "✔ platforms: linux/amd64 linux/arm64/v8"
	has_line "rc=0"
}

@test "check_platforms: anything else fails with the platforms it found" {
	lib check_platforms "$FIXTURES/index-public-3.1.4.json" the-index
	has_line "✘ expected exactly linux/amd64 and linux/arm64, found: linux/amd64 linux/arm64 unknown/unknown unknown/unknown"
	has_line "rc=1"
	platforms single '.manifests |= map(select(.platform.architecture == "amd64"))'
	has_line "✘ expected exactly linux/amd64 and linux/arm64, found: linux/amd64"
	platforms v7 '(.manifests[] | select(.platform.architecture == "arm64") | .platform.variant) = "v7"'
	has_line "✘ expected exactly linux/amd64 and linux/arm64, found: linux/amd64 linux/arm64/v7"
	platforms amd64v2 '(.manifests[] | select(.platform.architecture == "amd64") | .platform.variant) = "v2"'
	has_line "✘ expected exactly linux/amd64 and linux/arm64, found: linux/amd64/v2 linux/arm64"
	platforms empty '.manifests = []'
	has_line "✘ expected exactly linux/amd64 and linux/arm64, found: nothing"
	platforms twice '.manifests += .manifests'
	has_line "✘ expected exactly linux/amd64 and linux/arm64, found: linux/amd64 linux/amd64 linux/arm64 linux/arm64"
	has_line "rc=1"
}

@test "check_platforms: an index it can't read fails, as does one entry posing as two" {
	printf '<html>not json</html>' >"$BATS_TEST_TMPDIR/not-json"
	lib check_platforms "$BATS_TEST_TMPDIR/not-json" the-index
	has_line "✘ could not read the platforms of the-index"
	has_line "rc=1"
	platforms posing '.manifests = [.manifests[0] | .platform.architecture = "amd64 linux/arm64"]'
	has_line "✘ could not read the platforms of the-index"
	has_line "rc=1"
	lacks_text "✔"
}

# --- HTTP helpers ------------------------------------------------------------------------------------------------

@test "list_tags: follows the recorded page link and lists every tag" {
	route "$(token_url)" token
	route "$(tags_url)" tags-page1
	route "$(page2_url)" tags-page2
	lib list_tags "$BATS_TEST_TMPDIR/tags"
	has_line "rc=0"
	grep -qxF 3.1.4 "$BATS_TEST_TMPDIR/tags"
	grep -qxF latest "$BATS_TEST_TMPDIR/tags"
	expect_eq "$(calls_to "$(page2_url)")" 1
}
