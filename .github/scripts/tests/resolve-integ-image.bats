#!/usr/bin/env bats
#
# Tests for resolve-integ-image.sh (integ.yml's "Resolve image" step).

load test_helper

SCRIPT="$SCRIPTS_DIR/resolve-integ-image.sh"
DIGEST=sha256:cb376bab6ab0deb8083251f52a36f38b25251f53ef0671c0c1e0f7ab843e08e6
PUBLIC=public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws

setup() {
	export GITHUB_ENV="$BATS_TEST_TMPDIR/github_env"
	: >"$GITHUB_ENV"
	export IMAGE_REPO=$PUBLIC TAG_AMD64=3.1.4 TAG_ARM64=3.1.4 IMAGE_TAG=3.1.4 IMAGE_DIGEST=""
}

resolve() {
	run bash "$SCRIPT"
}

# The repo is refused and nothing reaches $GITHUB_ENV.
refuses_repo() {
	export IMAGE_REPO=$1
	resolve
	expect_status 1
	has_line "✘ imageRepo '$1' is not an allowed registry path (public.ecr.aws/<a>/<b>, ghcr.io/<a>/<b>, or <account>.dkr.ecr.<region>.amazonaws.com/<a>)"
	expect_eq "$(cat "$GITHUB_ENV")" ""
}

accepts_repo() {
	export IMAGE_REPO=$1
	: >"$GITHUB_ENV"
	resolve
	expect_status 0
	expect_eq "$(cat "$GITHUB_ENV")" "PRIVTAG=3.1.4"
}

@test "tag only: PRIVTAG is the tag" {
	resolve
	expect_status 0
	expect_eq "$(cat "$GITHUB_ENV")" "PRIVTAG=3.1.4"
	has_line "✔ image: $PUBLIC:3.1.4"
}

@test "tag and digest: PRIVTAG is tag@digest, written exactly once" {
	export IMAGE_DIGEST=$DIGEST
	resolve
	expect_status 0
	expect_eq "$(cat "$GITHUB_ENV")" "PRIVTAG=3.1.4@$DIGEST"
	expect_eq "$(grep -c '^PRIVTAG=' "$GITHUB_ENV")" 1
}

@test "the 3 real repo shapes are accepted" {
	accepts_repo "$PUBLIC"
	accepts_repo ghcr.io/aws/test-build
	accepts_repo 123456789012.dkr.ecr.us-west-2.amazonaws.com/ascp
	accepts_repo 123456789012.dkr.ecr.ap-southeast-1.amazonaws.com/ascp
}

@test "an empty tag is refused" {
	export TAG_AMD64="" IMAGE_TAG=""
	resolve
	expect_status 1
	has_line "✘ TAG_AMD64 '' is not a valid image tag"
	has_line "✘ IMAGE_TAG '' is not a valid image tag"
	expect_eq "$(cat "$GITHUB_ENV")" ""
}

@test "every cell checks both tags: a bad arm64 tag fails the amd64 cell too" {
	export TAG_ARM64="-bad"
	resolve
	expect_status 1
	has_line "✘ TAG_ARM64 '-bad' is not a valid image tag"
	expect_eq "$(cat "$GITHUB_ENV")" ""
}

@test "a tag that is too long is refused" {
	TAG_AMD64="a$(printf 'b%.0s' $(seq 1 128))"
	export TAG_AMD64
	resolve
	expect_status 1
	has_line "✘ TAG_AMD64 '$TAG_AMD64' is not a valid image tag"
	expect_eq "$(cat "$GITHUB_ENV")" ""
}

@test "a bad digest is refused" {
	local bad
	for bad in sha256:bad "sha256:${DIGEST#sha256:}0" "SHA256:${DIGEST#sha256:}" "sha256:$(echo "${DIGEST#sha256:}" | tr 'a-f' 'A-F')" "sha512:${DIGEST#sha256:}"; do
		export IMAGE_DIGEST=$bad
		resolve
		expect_status 1
		has_line "✘ imageDigest '$bad' is not sha256:<64 lowercase hex>"
		expect_eq "$(cat "$GITHUB_ENV")" ""
	done
}

@test "whitespace, line breaks and control characters are refused in every input" {
	local name value
	for name in IMAGE_REPO TAG_AMD64 TAG_ARM64 IMAGE_TAG IMAGE_DIGEST; do
		for value in "a b" $'a\nb' $'a\tb' $'a\rb' $'a\x01b'; do
			setup
			export "$name=$value"
			resolve
			expect_status 1
			has_line "✘ $name contains whitespace or control characters"
			expect_eq "$(cat "$GITHUB_ENV")" ""
		done
	done
}

@test "a line break can't inject a second variable into GITHUB_ENV" {
	export IMAGE_TAG=$'3.1.4\nAWS_REGION=evil'
	resolve
	expect_status 1
	expect_eq "$(cat "$GITHUB_ENV")" ""
}

@test "uppercase in the repo is refused" {
	refuses_repo ghcr.io/AWS/test-build
	refuses_repo PUBLIC.ECR.AWS/a/b
}

@test "look-alike hosts and bad path parts are refused" {
	refuses_repo public.ecr.aws.evil.com/x/y
	refuses_repo xpublic.ecr.aws/x/y
	refuses_repo ghcr.io/owner/repo-
	refuses_repo ghcr.io/_repo
	refuses_repo ghcr.io/owner/-repo
	refuses_repo ghcr.io/owner/repo..x
	refuses_repo ghcr.io/owner/repo___x
	refuses_repo .example.com/repo
	refuses_repo example..com/repo
	refuses_repo docker.io/library/ubuntu
	refuses_repo ""
}

@test "the account must be exactly 12 digits" {
	refuses_repo 12345678901.dkr.ecr.us-west-2.amazonaws.com/ascp
	refuses_repo 1234567890123.dkr.ecr.us-west-2.amazonaws.com/ascp
	refuses_repo 123456789012.dkr.ecr.us-west-2.amazonaws.com.evil/ascp
	refuses_repo 123456789012.dkr.ecr.uswest2.amazonaws.com/ascp
}

@test "all 3 patterns are anchored at the start" {
	refuses_repo evil.com/public.ecr.aws/a/b
	refuses_repo evil.com/ghcr.io/a/b
	refuses_repo evil.com/123456789012.dkr.ecr.us-west-2.amazonaws.com/ascp
}

@test "all 3 patterns are anchored at the end" {
	refuses_repo public.ecr.aws/a/b/c
	refuses_repo ghcr.io/owner/repo/x
	refuses_repo 123456789012.dkr.ecr.us-west-2.amazonaws.com/ascp/x
	refuses_repo 123456789012.dkr.ecr.us-west-2.amazonaws.com/ascp@y
	refuses_repo public.ecr.aws/a/b:tag
}

@test "every dot is literal in all 3 patterns" {
	# One wrong character per case, so each escaped dot is tested on its own.
	refuses_repo publicXecr.aws/x/y
	refuses_repo public.ecrXaws/x/y
	refuses_repo ghcr-io/a/b
	refuses_repo ghcrXio/a/b
	refuses_repo 123456789012Xdkr.ecr.us-west-2.amazonaws.com/ascp
	refuses_repo 123456789012.dkrXecr.us-west-2.amazonaws.com/ascp
	refuses_repo 123456789012.dkr.ecrXus-west-2.amazonaws.com/ascp
	refuses_repo 123456789012.dkr.ecr.us-west-2-amazonaws.com/ascp
	refuses_repo 123456789012.dkr.ecr.us-west-2.amazonawsXcom/ascp
}

@test "a repo longer than 255 characters is refused" {
	refuses_repo "ghcr.io/owner/$(printf 'a%.0s' $(seq 1 250))"
}

@test "an unset GITHUB_ENV is a failure, not a crash" {
	unset GITHUB_ENV
	resolve
	expect_status 1
	has_line "✘ GITHUB_ENV is not set"
}
