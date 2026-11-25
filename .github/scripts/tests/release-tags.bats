#!/usr/bin/env bats
#
# Tests for release-tags.sh (the Release workflow's tag, build-arg and label step).

load test_helper

SCRIPT="$SCRIPTS_DIR/release-tags.sh"
REGISTRY=123456789012.dkr.ecr.us-west-2.amazonaws.com
SHA=0123456789abcdef0123456789abcdef01234567
MODULE=github.com/aws/secrets-store-csi-driver-provider-aws
LABEL=com.amazonaws.secrets-store-csi-driver-provider-aws.release

setup() {
	export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	: >"$GITHUB_OUTPUT"
	export VERSION=3.1.5 PRACTICE=true STAGING_REGISTRY=$REGISTRY GITHUB_RUN_ID=987654321 GITHUB_RUN_ATTEMPT=2
	export GITHUB_SHA=$SHA
}

run_tags() {
	run bash "$SCRIPT"
}

# The script refuses with this message and writes nothing.
refuses() {
	run_tags
	expect_status 1
	has_line "$1"
	expect_eq "$(cat "$GITHUB_OUTPUT")" ""
}

@test "practice run: rehearsal tags, labels with mode practice" {
	run_tags
	expect_status 0
	expect_eq "$(cat "$GITHUB_OUTPUT")" "imageRepo=$REGISTRY/ascp
region=us-west-2
accountId=123456789012
testingTag=rehearsal-987654321-testing
stageTag=rehearsal-987654321
buildArgs=LDFLAGS=-X '$MODULE/server.Version=3.1.5' -X '$MODULE/server.ProviderVersion=3.1.5' -extldflags '-static'
labels<<RELEASE_TAGS_EOF
org.opencontainers.image.revision=$SHA
$LABEL.run=987654321-2
$LABEL.mode=practice
RELEASE_TAGS_EOF"
	has_line "✔ practice run"
}

@test "real run: version tags, labels with mode real" {
	export PRACTICE=false
	run_tags
	expect_status 0
	expect_eq "$(cat "$GITHUB_OUTPUT")" "imageRepo=$REGISTRY/ascp
region=us-west-2
accountId=123456789012
testingTag=3.1.5-testing
stageTag=3.1.5
buildArgs=LDFLAGS=-X '$MODULE/server.Version=3.1.5' -X '$MODULE/server.ProviderVersion=3.1.5' -extldflags '-static'
labels<<RELEASE_TAGS_EOF
org.opencontainers.image.revision=$SHA
$LABEL.run=987654321-2
$LABEL.mode=real
RELEASE_TAGS_EOF"
	has_line "✔ real run"
}

@test "the build args match the ones go version -m was recorded with" {
	export VERSION=3.1.4
	run_tags
	expect_status 0
	local line recorded
	line=$(grep '^buildArgs=' "$GITHUB_OUTPUT")
	recorded=$(grep $'^\tbuild\t-ldflags=' "$FIXTURES/go-version-m-amd64.txt")
	expect_eq "\"${line#buildArgs=LDFLAGS=}\"" "${recorded#*-ldflags=}"
}

# The Makefile sets the same flags for `make docker-buildx`. make prints them with the shell quotes already removed,
# and xargs removes the single quotes from ours, so both sides become one flag per line. LDFLAGS is unset for make, so
# a value in the shell (common on macOS) can't replace the Makefile's own.
@test "the build args match the Makefile's LDFLAGS" {
	local version flags line
	version=$(make -s -f "$REAL_REPO/Makefile" -f <(printf 'print-version:\n\t@echo $(FULL_REV)\n') print-version)
	flags=$(env -u LDFLAGS make -s -f "$REAL_REPO/Makefile" -f <(printf 'print-ldflags:\n\t@echo $(LDFLAGS)\n') \
		print-ldflags)
	export VERSION=$version
	run_tags
	expect_status 0
	line=$(grep '^buildArgs=' "$GITHUB_OUTPUT")
	expect_eq "$(xargs printf '%s\n' <<<"${line#buildArgs=LDFLAGS=}")" "$(tr ' ' '\n' <<<"$flags")"
}

@test "another region and account are read from the registry" {
	export STAGING_REGISTRY=111122223333.dkr.ecr.ap-southeast-1.amazonaws.com
	run_tags
	expect_status 0
	grep -qx 'region=ap-southeast-1' "$GITHUB_OUTPUT"
	grep -qx 'accountId=111122223333' "$GITHUB_OUTPUT"
}

@test "a bad PRACTICE is refused" {
	local bad
	for bad in True FALSE yes 1 "true "; do
		export PRACTICE=$bad
		: >"$GITHUB_OUTPUT"
		refuses "✘ PRACTICE must be true or false, not $(printf '%q' "$bad")"
	done
}

@test "registry look-alikes are refused" {
	local bad
	for bad in "$REGISTRY/ascp" "$REGISTRY." "x$REGISTRY" 12345678901.dkr.ecr.us-west-2.amazonaws.com \
		123456789012.dkr.ecr.us-west-2.amazonaws.com.evil.example 123456789012.dkr.ecr.us-west.amazonaws.com \
		123456789012.dkr.ecr-fips.us-west-2.amazonaws.com public.ecr.aws "$REGISTRY"$'\n'; do
		export STAGING_REGISTRY=$bad
		refuses "✘ STAGING_REGISTRY $(printf '%q' "$bad") is not <account>.dkr.ecr.<region>.amazonaws.com"
	done
}

@test "every unset or empty input is refused by name" {
	local name
	for name in VERSION PRACTICE STAGING_REGISTRY GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_SHA; do
		setup
		unset "$name"
		refuses "✘ $name is not set"
		setup
		export "$name="
		refuses "✘ $name is not set"
	done
	setup
	unset GITHUB_OUTPUT
	run_tags
	expect_status 1
	has_line "✘ GITHUB_OUTPUT is not set"
}

@test "a bad version is refused, including one with a newline" {
	local bad
	for bad in v3.1.5 3.1 3.1.5-rc1 03.1.5 "3.1.5 " $'3.1.5\nLDFLAGS=x' 1.1.111111111111111111111111111111; do
		export VERSION=$bad
		refuses "✘ $(printf '%q' "$bad") is not a valid version (X.Y.Z)"
	done
}
