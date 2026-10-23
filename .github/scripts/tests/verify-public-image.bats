#!/usr/bin/env bats
#
# Tests for verify-public-image.sh. The fake curl (fake-bin/) serves a made-up two-platform image: an index, its
# two image manifests and their config blobs, so the hashes the script computes are real. The fake also checks that
# the token request carries no Authorization header and every other request exactly the anonymous bearer token.

load test_helper

SCRIPT="$SCRIPTS_DIR/verify-public-image.sh"
PROD=public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws
OTHER_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
PREVIOUS_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222
ALIASES="latest-amd64 latest-arm64 latest-linux-amd64 latest-linux-arm64 3 latest"
CREDENTIAL_VARS="AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN AWS_PROFILE AWS_WEB_IDENTITY_TOKEN_FILE
AWS_ROLE_ARN AWS_SHARED_CREDENTIALS_FILE AWS_CONFIG_FILE AWS_CONTAINER_CREDENTIALS_RELATIVE_URI
AWS_CONTAINER_CREDENTIALS_FULL_URI"

setup() {
	common_setup
	local name
	for name in $CREDENTIAL_VARS; do
		unset "$name"
	done
	export REGISTRY_URL=$ECR REGISTRY_RETRY_SCALE=0 REGISTRY_PACE_SECONDS=0 FAKE_CURL_MANIFEST_GET=1
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$TMPDIR"
	export PRACTICE=false PUBLIC_REPO=$PROD VERSION_TAGS="3.1.5 3.1.5-linux-amd64 3.1.5-linux-arm64"
	make_image
	good_routes
}

teardown() {
	common_teardown
}

verify() {
	run bash "$SCRIPT" "$@"
}

sha_hex() { python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'; }
file_digest() { echo "sha256:$(sha_hex <"$1")"; }
blob_url() { echo "$ECR/v2/$REPO_PATH/blobs/$1"; }

# manifest_reply <name> <body file> [digest] : a 200 reply with that body and, given a digest, the
# docker-content-digest header ECR Public sends on HEAD.
manifest_reply() {
	{
		printf 'HTTP/2 200 \r\ncontent-type: application/vnd.oci.image.index.v1+json\r\n'
		if [[ -n "${3:-}" ]]; then
			printf 'docker-content-digest: %s\r\n' "$3"
		fi
		printf 'docker-distribution-api-version: registry/2.0\r\n\r\n'
	} >"$FAKE_DIR/fixtures/$1.headers"
	cp "$2" "$FAKE_DIR/fixtures/$1.body"
}

# An index of two image manifests, each with its own config. Sets DIGEST, IMAGE_<ARCH> and CONFIG_<ARCH>.
make_image() {
	local dir="$BATS_TEST_TMPDIR/image"
	mkdir -p "$dir"
	CONFIG_AMD64="sha256:$(printf config-amd64 | sha_hex)"
	CONFIG_ARM64="sha256:$(printf config-arm64 | sha_hex)"
	printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"%s","size":12},"layers":[]}' \
		"$CONFIG_AMD64" >"$dir/amd64.json"
	printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","config":{"mediaType":"application/vnd.oci.image.config.v1+json","digest":"%s","size":12},"layers":[]}' \
		"$CONFIG_ARM64" >"$dir/arm64.json"
	IMAGE_AMD64=$(file_digest "$dir/amd64.json")
	IMAGE_ARM64=$(file_digest "$dir/arm64.json")
	printf '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.index.v1+json","manifests":[{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":1,"platform":{"architecture":"amd64","os":"linux"}},{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":1,"platform":{"architecture":"arm64","os":"linux"}}]}' \
		"$IMAGE_AMD64" "$IMAGE_ARM64" >"$dir/index.json"
	DIGEST=$(file_digest "$dir/index.json")
	export DIGEST
	manifest_reply index "$dir/index.json" "$DIGEST"
	manifest_reply other "$dir/index.json" "$OTHER_DIGEST"
	manifest_reply no-digest-header "$dir/index.json"
	manifest_reply image-amd64 "$dir/amd64.json"
	manifest_reply image-arm64 "$dir/arm64.json"
	# ECR Public answers a blob GET with a redirect to the download.
	printf 'HTTP/2 307 \r\ncontent-length: 0\r\nlocation: https://blobs.example/config\r\n\r\n' \
		>"$FAKE_DIR/fixtures/blob.headers"
}

# set_route <url> <fixture>[,<fixture>...] : replaces any earlier route for the URL.
set_route() {
	awk -v url="$1" '$1 != url' "$FAKE_DIR/routes" >"$FAKE_DIR/routes.new"
	mv "$FAKE_DIR/routes.new" "$FAKE_DIR/routes"
	route "$1" "$2"
}

good_routes() {
	local tag
	route "$(token_url)" token
	for tag in $VERSION_TAGS; do
		route "$(manifest_url "$tag")" index
	done
	route "$(manifest_url "$IMAGE_AMD64")" image-amd64
	route "$(manifest_url "$IMAGE_ARM64")" image-arm64
	route "$(blob_url "$CONFIG_AMD64")" blob
	route "$(blob_url "$CONFIG_ARM64")" blob
}

# The alias-tags inputs and routes: every alias serves the tested digest, and the digest list holds absent and one
# earlier digest.
alias_routes() {
	local tag
	export ALIAS_TAGS=$ALIASES PREVIOUS_DIGESTS="[null,\"$PREVIOUS_DIGEST\"]"
	manifest_reply previous "$BATS_TEST_TMPDIR/image/index.json" "$PREVIOUS_DIGEST"
	for tag in $ALIASES; do
		route "$(manifest_url "$tag")" index
	done
}

# The URLs the fake curl was called with, in order.
call_urls() { awk '{ print $2 }' "$FAKE_DIR/curl.calls"; }

@test "version-tags: reads each tag, image and config once, anonymously, and passes" {
	verify version-tags
	expect_status 0
	expect_eq "$(call_urls)" "$(token_url)
$(manifest_url 3.1.5)
$(manifest_url 3.1.5)
$(manifest_url 3.1.5-linux-amd64)
$(manifest_url 3.1.5-linux-amd64)
$(manifest_url 3.1.5-linux-arm64)
$(manifest_url 3.1.5-linux-arm64)
$(manifest_url "$IMAGE_AMD64")
$(blob_url "$CONFIG_AMD64")
$(manifest_url "$IMAGE_ARM64")
$(blob_url "$CONFIG_ARM64")"
	has_line "✔ no AWS credential variables are set"
	has_line "✔ 3.1.5 points at $DIGEST"
	has_line "✔ 3.1.5-linux-arm64 points at $DIGEST"
	has_line "✔ platforms: linux/amd64 linux/arm64"
	has_line "✔ image $IMAGE_ARM64 and its config $CONFIG_ARM64 are public"
	has_line "✔ $PROD@$DIGEST is public as $VERSION_TAGS, with every image and config it lists"
	lacks_text fake-token
}

@test "version-tags: a tag on another digest stops at once, naming both digests" {
	set_route "$(manifest_url 3.1.5-linux-amd64)" other
	verify version-tags
	expect_status 1
	has_line "✘ 3.1.5-linux-amd64 points at $OTHER_DIGEST, not the tested $DIGEST: it is on another image; stopping"
	expect_eq "$(calls_to "$(manifest_url 3.1.5-linux-amd64)")" 1
	expect_eq "$(calls_to "$(manifest_url 3.1.5-linux-arm64)")" 0
	expect_eq "$(calls_to "$(manifest_url "$IMAGE_AMD64")")" 0
}

@test "version-tags: a 404 or a 429 is retried until the tag shows the tested digest" {
	set_route "$(manifest_url 3.1.5)" manifest-404,status-429,index
	set_route "$(blob_url "$CONFIG_ARM64")" manifest-404,blob
	verify version-tags
	expect_status 0
	# 3 HEADs and the GET.
	expect_eq "$(calls_to "$(manifest_url 3.1.5)")" 4
	expect_eq "$(calls_to "$(blob_url "$CONFIG_ARM64")")" 2
	has_line "  HTTP 404 for $(manifest_url 3.1.5), retrying in 0 s"
	has_line "  HTTP 429 for $(manifest_url 3.1.5), retrying in 0 s"
	has_line "✔ 3.1.5 points at $DIGEST"
}

@test "version-tags: a lasting failure fails closed after 8 attempts" {
	set_route "$(manifest_url 3.1.5)" manifest-404
	verify version-tags
	expect_status 1
	expect_eq "$(calls_to "$(manifest_url 3.1.5)")" 8
	has_line "  HTTP 404 after 8 attempts for $(manifest_url 3.1.5)"
	has_line "✘ could not read 3.1.5 (see the error above)"
	lacks_text "✔ 3.1.5 points"
	lacks_text "✔ $PROD@"
}

@test "version-tags: refuses to start if any AWS credential variable is set, even to nothing" {
	local name
	for name in $CREDENTIAL_VARS; do
		export "$name=x"
		verify version-tags
		unset "$name"
		expect_status 1
		has_line "✘ $name is set"
		has_line "✘ this check must run with no way to get AWS credentials; remove the variables above from the job"
	done
	export AWS_PROFILE=""
	verify version-tags
	unset AWS_PROFILE
	expect_status 1
	has_line "✘ AWS_PROFILE is set"
	expect_eq "$(count_lines "$FAKE_DIR/curl.calls")" 0
}

@test "version-tags: every image in the index is hashed before its config blob is read" {
	# The amd64 image's URL serves the arm64 image.
	set_route "$(manifest_url "$IMAGE_AMD64")" image-arm64
	verify version-tags
	expect_status 1
	has_line "✘ image $IMAGE_AMD64 serves a manifest that hashes to $IMAGE_ARM64; stopping"
	expect_eq "$(calls_to "$(blob_url "$CONFIG_AMD64")")" 0
}

@test "alias-tags: reads each alias once, anonymously, and passes" {
	local tag expected
	alias_routes
	verify alias-tags
	expect_status 0
	expected=$(token_url)
	for tag in $ALIASES; do
		expected="$expected"$'\n'"$(manifest_url "$tag")"
	done
	expect_eq "$(call_urls)" "$expected"
	has_line "✔ latest points at $DIGEST"
	has_line "✔ every alias of $PROD points at $DIGEST: $ALIASES"
	lacks_text fake-token
}

@test "alias-tags: an alias not found, or on a digest from before this run, is read until it shows the tested digest" {
	alias_routes
	set_route "$(manifest_url latest)" manifest-404,previous,index
	verify alias-tags
	expect_status 0
	expect_eq "$(calls_to "$(manifest_url latest)")" 3
	has_line "  latest shows not found; reading it again in 0 s"
	has_line "  latest shows $PREVIOUS_DIGEST, a digest from before this run; reading it again in 0 s"
	has_line "✔ latest points at $DIGEST"
}

@test "alias-tags: an alias that keeps a digest from before this run fails closed after 8 reads" {
	alias_routes
	set_route "$(manifest_url latest-arm64)" previous
	verify alias-tags
	expect_status 1
	expect_eq "$(calls_to "$(manifest_url latest-arm64)")" 8
	has_line "✘ after 8 reads, latest-arm64 shows $PREVIOUS_DIGEST, a digest from before this run, not the tested $DIGEST"
	expect_eq "$(calls_to "$(manifest_url latest)")" 0
	lacks_text "✔ every alias"
}

@test "alias-tags: an alias on any other digest stops at once" {
	alias_routes
	set_route "$(manifest_url 3)" other
	verify alias-tags
	expect_status 1
	has_line "✘ 3 points at $OTHER_DIGEST, not the tested $DIGEST: it is on another image; stopping"
	expect_eq "$(calls_to "$(manifest_url 3)")" 1
	expect_eq "$(calls_to "$(manifest_url latest)")" 0
}

@test "alias-tags: a digest list that is not JSON null or other sha256 digests fails before any request" {
	local list
	alias_routes
	for list in 'not json' '{}' '["sha256:abc"]' "[null,\"$DIGEST\"]" '[1]'; do
		PREVIOUS_DIGESTS=$list verify alias-tags
		expect_status 1
		has_line "✘ PREVIOUS_DIGESTS $(printf '%q' "$list") is not a JSON list of null and sha256:<64 hex> digests other than $DIGEST"
	done
	expect_eq "$(count_lines "$FAKE_DIR/curl.calls")" 0
}
