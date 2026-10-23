#!/usr/bin/env bats
#
# Tests for chart-image-public.sh, the chart release's preflight. The fake curl (fake-bin/) replays recorded ECR
# Public replies, and checks that the token request carries no Authorization header and that the manifest HEAD
# carries exactly the anonymous bearer token.

load test_helper

SCRIPT="$SCRIPTS_DIR/chart-image-public.sh"
PROD=public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws

setup() {
	common_setup
	export REGISTRY_URL=$ECR REGISTRY_RETRY_SCALE=0 REGISTRY_PACE_SECONDS=0
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$TMPDIR"
	export IMAGE_REPO=$PROD IMAGE_TAG=3.1.4
	route "$(token_url)" token
}

teardown() {
	common_teardown
}

check() {
	run bash "$SCRIPT"
}

@test "passes when the tag's manifest pulls anonymously" {
	route "$(manifest_url 3.1.4)" manifest-200
	check
	expect_status 0
	has_line "✔ $PROD:3.1.4 is public"
	expect_eq "$(calls_to "$(token_url)")" 1
	expect_eq "$(calls_to "$(manifest_url 3.1.4)")" 1
	lacks_text fake-token
}

@test "a tag that is not found fails at once: not published" {
	route "$(manifest_url 3.1.4)" manifest-404
	check
	expect_status 1
	has_line "::error::$PROD:3.1.4 is not published: release the image first, then the chart"
	expect_eq "$(calls_to "$(manifest_url 3.1.4)")" 1
}

@test "a 401 or 403 fails at once: not public" {
	local code
	for code in 401 403; do
		common_setup
		route "$(token_url)" token
		route "$(manifest_url 3.1.4)" "status-$code"
		check
		expect_status 1
		has_line "::error::$PROD:3.1.4 is not public (HTTP $code): an anonymous pull is refused"
		expect_eq "$(calls_to "$(manifest_url 3.1.4)")" 1
	done
}

@test "a lasting network error fails closed after 8 attempts" {
	route "$(manifest_url 3.1.4)" neterror
	check
	expect_status 1
	expect_eq "$(calls_to "$(manifest_url 3.1.4)")" 8
	has_line "::error::could not read $PROD:3.1.4 (see the error above)"
	lacks_text "✔"
}

@test "refuses any repo but the production one, before any request" {
	local repo
	for repo in "" public.ecr.aws/example-sandbox/secrets-store-csi-driver-provider-aws "$PROD/" \
		"${PROD}x" "docker.io/aws-secrets-manager/secrets-store-csi-driver-provider-aws"; do
		IMAGE_REPO=$repo check
		expect_status 1
		has_line "::error::values.yaml image.repository is $(printf '%q' "$repo"), not the production repo $PROD"
	done
	expect_eq "$(count_lines "$FAKE_DIR/curl.calls")" 0
}
