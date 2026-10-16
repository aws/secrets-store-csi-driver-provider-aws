#!/usr/bin/env bats
#
# Tests for staging-image.sh (the Release workflow's steps against the private staging repo). Fake aws, docker and
# go (fake-bin/) answer from per-test replies, so no test touches AWS or a registry.

load test_helper

SCRIPT="$SCRIPTS_DIR/staging-image.sh"
ACCOUNT=123456789012
REGISTRY=$ACCOUNT.dkr.ecr.us-west-2.amazonaws.com
REPO=$REGISTRY/ascp
OCI_INDEX=application/vnd.oci.image.index.v1+json
OTHER_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
TIMEOUTS="--output json --cli-read-timeout 30 --cli-connect-timeout 10"
ECR_ARGS="--registry-id $ACCOUNT --repository-name ascp --region us-west-2"

setup() {
	common_setup
	mkdir -p "$FAKE_DIR/aws"
	: >"$FAKE_DIR/aws.routes"
	: >"$FAKE_DIR/aws.calls"
	: >"$FAKE_DIR/aws.keys"
	: >"$FAKE_DIR/docker.calls"
	: >"$FAKE_DIR/go.calls"
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

	# The recorded public 3.1.4 index without its 2 attestation entries: the 2-platform index the build pushes
	# (provenance and sbom are off). Made from recorded bytes; ECR's own reply for it is not recorded.
	GOOD_INDEX="$BATS_TEST_TMPDIR/good-index.json"
	jq -c '.manifests |= map(select(.platform.os != "unknown"))' "$FIXTURES/index-public-3.1.4.json" |
		tr -d '\n' >"$GOOD_INDEX"
	export DIGEST="sha256:$(digest_of "$GOOD_INDEX")"

	export IMAGE_REPO=$REPO AWS_REGION=us-west-2 AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=5
	export PRACTICE=true STAGE_TAG=rehearsal-7 TESTING_TAG=rehearsal-7-testing VERSION=3.1.4
	export ROOTFS="$BATS_TEST_TMPDIR/rootfs" GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	common_teardown
}

staging() {
	run bash "$SCRIPT" "$@"
}

digest_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

# --- fake aws replies --------------------------------------------------------------------------------------------

# aws_route <key> <reply>[,<reply>...] : replaces any earlier route for the key.
aws_route() {
	awk -v key="$1" '$1 != key' "$FAKE_DIR/aws.routes" >"$FAKE_DIR/aws.routes.new"
	echo "$1 $2" >>"$FAKE_DIR/aws.routes.new"
	mv "$FAKE_DIR/aws.routes.new" "$FAKE_DIR/aws.routes"
}

# aws_reply <name> <json>
aws_reply() { printf '%s\n' "$2" >"$FAKE_DIR/aws/$1.out"; }

# aws_error <name> <ErrorName> <Operation> <message> : a service error in the recorded CLI v2 format, exit 254.
aws_error() {
	printf '\naws: [ERROR]: An error occurred (%s) when calling the %s operation: %s\n' "$2" "$3" "$4" \
		>"$FAKE_DIR/aws/$1.err"
	echo 254 >"$FAKE_DIR/aws/$1.exit"
}

# describe_reply <name> <digest> <tag>... : describe-images finds one image with these tags.
describe_reply() {
	local name=$1 digest=$2
	shift 2
	aws_reply "$name" "$(jq -n --arg d "$digest" --arg a "$ACCOUNT" '
		{imageDetails: [{registryId: $a, repositoryName: "ascp", imageDigest: $d,
			imageTags: $ARGS.positional, imageSizeInBytes: 18003485, imagePushedAt: "2026-10-16T10:00:00-07:00",
			imageManifestMediaType: "application/vnd.oci.image.index.v1+json"}]}' --args "$@")"
}

# manifest_reply <name> <manifest file> [media type] : batch-get-image returns these exact bytes.
manifest_reply() {
	local name=$1 file=$2 type=${3:-$OCI_INDEX}
	aws_reply "$name" "$(jq -n --rawfile m "$file" --arg d "$DIGEST" --arg a "$ACCOUNT" --arg t "$type" '
		{images: [{registryId: $a, repositoryName: "ascp", imageId: {imageDigest: $d}, imageManifest: $m,
			imageManifestMediaType: $t}], failures: []}')"
}

# A replacement index: writes it, sets DIGEST to its hash, and routes batch-get-image to it.
use_index() {
	local file="$BATS_TEST_TMPDIR/index-$1.json"
	printf '%s' "$2" >"$file"
	DIGEST="sha256:$(digest_of "$file")"
	manifest_reply "index-$1" "$file" "${3:-$OCI_INDEX}"
	echo "$file"
}

not_found() {
	aws_error "$1" ImageNotFoundException DescribeImages \
		"The image with imageId {imageDigest:'null', imageTag:'$STAGE_TAG'} does not exist within the repository with name 'ascp' in the registry with id '$ACCOUNT'"
}

# Routes for a pushed build that passes every check-build check.
good_build_routes() {
	manifest_reply index "$GOOD_INDEX"
	aws_route "batch-get-image:imageDigest=$DIGEST" index
	describe_reply digest-tags "$DIGEST" "$TESTING_TAG"
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	make_rootfs
}

# The build's local copy: linux_amd64/ and linux_arm64/, each with the binary and the certificate folders.
make_rootfs() {
	local arch
	for arch in amd64 arm64; do
		mkdir -p "$ROOTFS/linux_$arch/bin" "$ROOTFS/linux_$arch/etc/pki" "$ROOTFS/linux_$arch/etc/ssl/certs"
		: >"$ROOTFS/linux_$arch/bin/secrets-store-csi-driver-provider-aws"
		go_output "$arch" "s/3\\.1\\.4/$VERSION/g"
	done
}

# go_output <arch> <sed expression> : the recorded `go version -m` output for <arch>, edited.
go_output() {
	sed -E "$2" "$FIXTURES/go-version-m-$1.txt" >"$FAKE_DIR/go-$1.out"
}

# Routes for a fresh stage: no other-mode tags, the tag is free, put-image works, and the tag then points at DIGEST.
fresh_stage_routes() {
	describe_reply digest-tags "$DIGEST" "$STAGE_TAG-testing"
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	not_found tag-missing
	describe_reply tag-staged "$DIGEST" "$STAGE_TAG-testing" "$STAGE_TAG"
	aws_route "describe-images:imageTag=$STAGE_TAG" tag-missing,tag-staged
	manifest_reply index "$GOOD_INDEX"
	aws_route "batch-get-image:imageDigest=$DIGEST" index
	aws_reply put-ok '{"image": {}}'
	aws_route "put-image:$STAGE_TAG" put-ok
}

calls_for() { grep -c "^$1 " "$FAKE_DIR/aws.calls" || true; }

# --- no-env-credentials ------------------------------------------------------------------------------------------

@test "no-env-credentials: passes with no AWS keys in the environment" {
	staging no-env-credentials
	expect_status 0
	has_line "✔ no AWS credentials in the job environment"
}

@test "no-env-credentials: each AWS key, even empty, fails" {
	local name
	for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
		export "$name=x"
		staging no-env-credentials
		expect_status 1
		has_line "✘ $name is set in the job environment"
		export "$name="
		staging no-env-credentials
		expect_status 1
		unset "$name"
	done
}

# --- check-free --------------------------------------------------------------------------------------------------

@test "check-free: a tag that isn't there is free" {
	not_found missing
	aws_route "describe-images:imageTag=rehearsal-7" missing
	staging check-free
	expect_status 0
	has_line "✔ rehearsal-7 is free"
	expect_eq "$(cat "$FAKE_DIR/aws.calls")" \
		"describe-images $ECR_ARGS --image-ids imageTag=rehearsal-7 $TIMEOUTS | retry=standard,5"
}

@test "check-free: a staged tag fails" {
	export PRACTICE=false STAGE_TAG=3.1.5 TESTING_TAG=3.1.5-testing
	describe_reply found "$DIGEST" 3.1.5 3.1.5-testing
	aws_route "describe-images:imageTag=3.1.5" found
	staging check-free
	expect_status 1
	has_line "✘ 3.1.5 is already staged (at $DIGEST); tags there are permanent, so start a new run"
}

@test "check-free: any other error fails, never 'free'" {
	aws_error denied AccessDeniedException DescribeImages "User is not authorized to perform: ecr:DescribeImages"
	aws_route "describe-images:imageTag=rehearsal-7" denied
	staging check-free
	expect_status 1
	has_line "✘ could not check rehearsal-7 (exit 254)"
	lacks_text "is free"
}

@test "check-free: a failure without an AWS error name is a plain failure" {
	printf 'Connect timeout on endpoint URL: "https://api.ecr.us-west-2.amazonaws.com/"\n' >"$FAKE_DIR/aws/timeout.err"
	echo 255 >"$FAKE_DIR/aws/timeout.exit"
	aws_route "describe-images:imageTag=rehearsal-7" timeout
	staging check-free
	expect_status 1
	has_line "✘ could not check rehearsal-7 (exit 255)"
}

@test "check-free: an error that only mentions ImageNotFoundException in its message is not 'not found'" {
	aws_error odd ValidationException DescribeImages "see ImageNotFoundException"
	aws_route "describe-images:imageTag=rehearsal-7" odd
	staging check-free
	expect_status 1
	has_line "✘ could not check rehearsal-7 (exit 254)"
}

# --- login / logout ----------------------------------------------------------------------------------------------

@test "login: pipes the password into docker login and prints neither" {
	echo fake-ecr-password >"$FAKE_DIR/aws/password.out"
	aws_route get-login-password password
	staging login
	expect_status 0
	has_line "✔ logged in to $REGISTRY"
	lacks_text fake-ecr-password
	expect_eq "$(cat "$FAKE_DIR/docker.password")" fake-ecr-password
	expect_eq "$(cat "$FAKE_DIR/docker.calls")" "login --username AWS --password-stdin $REGISTRY"
	expect_eq "$(cat "$FAKE_DIR/aws.calls")" \
		"get-login-password --region us-west-2 --cli-read-timeout 30 --cli-connect-timeout 10 | retry=standard,5"
}

@test "login: a get-login-password failure fails the login (pipefail)" {
	aws_error expired ExpiredTokenException GetAuthorizationToken "The security token included in the request is expired"
	aws_route get-login-password expired
	staging login
	expect_status 1
	has_line "✘ could not log in to $REGISTRY (exit 254)"
}

@test "login: a docker login failure fails" {
	echo fake-ecr-password >"$FAKE_DIR/aws/password.out"
	aws_route get-login-password password
	echo exit:1 >"$FAKE_DIR/docker.login"
	staging login
	expect_status 1
	has_line "✘ could not log in to $REGISTRY (exit 1)"
	lacks_text fake-ecr-password
}

@test "logout: logs out of the registry" {
	echo "$REGISTRY" >"$FAKE_DIR/docker.logged-in"
	staging logout
	expect_status 0
	has_line "Removing login credentials for $REGISTRY"
	expect_eq "$(cat "$FAKE_DIR/docker.calls")" "logout $REGISTRY"
}

@test "logout: passes when not logged in" {
	staging logout
	expect_status 0
	has_line "Not logged in to $REGISTRY"
}

@test "logout: an empty IMAGE_REPO is a quiet pass with no docker call" {
	export IMAGE_REPO=""
	staging logout
	expect_status 0
	expect_eq "$(count_lines "$FAKE_DIR/docker.calls")" 0
}

# --- check-build -------------------------------------------------------------------------------------------------

@test "check-build: a good index passes and writes the digest" {
	good_build_routes
	staging check-build
	expect_status 0
	has_line "✔ $DIGEST is an image index ($OCI_INDEX)"
	has_line "✔ platforms: linux/amd64 linux/arm64"
	has_line "✔ amd64 binary: linux/amd64, no cgo, version 3.1.4"
	has_line "✔ arm64 binary: linux/arm64, no cgo, version 3.1.4"
	has_line "✔ $DIGEST carries rehearsal-7-testing"
	expect_eq "$(cat "$GITHUB_OUTPUT")" "digest=$DIGEST"
	expect_eq "$(cat "$FAKE_DIR/aws.calls")" \
		"batch-get-image $ECR_ARGS --image-ids imageDigest=$DIGEST $TIMEOUTS | retry=standard,5
describe-images $ECR_ARGS --image-ids imageDigest=$DIGEST $TIMEOUTS | retry=standard,5"
}

@test "check-build: a real run with its own testing tag passes" {
	export PRACTICE=false VERSION=3.1.5 TESTING_TAG=3.1.5-testing
	good_build_routes
	staging check-build
	expect_status 0
	has_line "✔ amd64 binary: linux/amd64, no cgo, version 3.1.5"
}

@test "check-build: manifest bytes that don't hash to the digest fail" {
	good_build_routes
	printf '%s ' "$(cat "$GOOD_INDEX")" >"$BATS_TEST_TMPDIR/changed.json"
	manifest_reply index "$BATS_TEST_TMPDIR/changed.json"
	staging check-build
	expect_status 1
	has_line "✘ the manifest ECR returned hashes to sha256:$(digest_of "$BATS_TEST_TMPDIR/changed.json"), not $DIGEST"
	expect_eq "$(cat "$GITHUB_OUTPUT")" ""
}

@test "check-build: a reply that lists failures fails" {
	good_build_routes
	aws_reply index "$(jq -n --arg d "$DIGEST" \
		'{images: [], failures: [{imageId: {imageDigest: $d}, failureCode: "ImageNotFound", failureReason: "Requested image not found"}]}')"
	staging check-build
	expect_status 1
	has_line "✘ could not read the manifest of $DIGEST (the reply lists failures)"
}

@test "check-build: the recorded public index, with its 2 unknown/unknown attestations, fails" {
	good_build_routes
	DIGEST="sha256:$(digest_of "$FIXTURES/index-public-3.1.4.json")"
	manifest_reply index "$FIXTURES/index-public-3.1.4.json"
	aws_route "batch-get-image:imageDigest=$DIGEST" index
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	staging check-build
	expect_status 1
	has_line "✘ expected exactly linux/amd64 and linux/arm64, found: linux/amd64 linux/arm64 unknown/unknown unknown/unknown"
}

@test "check-build: a single-arch index fails" {
	good_build_routes
	use_index single "$(jq -c '.manifests |= map(select(.platform.architecture == "amd64"))' "$GOOD_INDEX")" >/dev/null
	aws_route "batch-get-image:imageDigest=$DIGEST" index-single
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	staging check-build
	expect_status 1
	has_line "✘ expected exactly linux/amd64 and linux/arm64, found: linux/amd64"
}

@test "check-build: arm64 variant v8 passes, another variant fails" {
	good_build_routes
	use_index v8 "$(jq -c '(.manifests[] | select(.platform.architecture == "arm64") | .platform.variant) = "v8"' "$GOOD_INDEX")" >/dev/null
	aws_route "batch-get-image:imageDigest=$DIGEST" index-v8
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	staging check-build
	expect_status 0
	has_line "✔ platforms: linux/amd64 linux/arm64/v8"

	setup
	good_build_routes
	use_index v7 "$(jq -c '(.manifests[] | select(.platform.architecture == "arm64") | .platform.variant) = "v7"' "$GOOD_INDEX")" >/dev/null
	aws_route "batch-get-image:imageDigest=$DIGEST" index-v7
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	staging check-build
	expect_status 1
	has_line "✘ expected exactly linux/amd64 and linux/arm64, found: linux/amd64 linux/arm64/v7"
}

@test "check-build: an amd64 variant fails" {
	good_build_routes
	use_index amd64v2 "$(jq -c '(.manifests[] | select(.platform.architecture == "amd64") | .platform.variant) = "v2"' "$GOOD_INDEX")" >/dev/null
	aws_route "batch-get-image:imageDigest=$DIGEST" index-amd64v2
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	staging check-build
	expect_status 1
	has_line "✘ expected exactly linux/amd64 and linux/arm64, found: linux/amd64/v2 linux/arm64"
}

@test "check-build: a media type that isn't an index fails" {
	good_build_routes
	manifest_reply index "$GOOD_INDEX" application/vnd.oci.image.manifest.v1+json
	staging check-build
	expect_status 1
	has_line "✘ $DIGEST is not an image index (media type application/vnd.oci.image.manifest.v1+json)"
}

@test "check-build: a Docker manifest list passes the media type check" {
	good_build_routes
	use_index list "$(jq -c '.mediaType = "application/vnd.docker.distribution.manifest.list.v2+json"' "$GOOD_INDEX")" \
		application/vnd.docker.distribution.manifest.list.v2+json >/dev/null
	aws_route "batch-get-image:imageDigest=$DIGEST" index-list
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	staging check-build
	expect_status 0
}

@test "check-build: a JSON mediaType that disagrees with ECR's fails" {
	good_build_routes
	use_index disagree "$(jq -c '.mediaType = "application/vnd.docker.distribution.manifest.list.v2+json"' "$GOOD_INDEX")" >/dev/null
	aws_route "batch-get-image:imageDigest=$DIGEST" index-disagree
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	staging check-build
	expect_status 1
	has_line "✘ the manifest says media type application/vnd.docker.distribution.manifest.list.v2+json, ECR says $OCI_INDEX"
}

@test "check-build: an index without its own mediaType passes" {
	good_build_routes
	use_index nojsontype "$(jq -c 'del(.mediaType)' "$GOOD_INDEX")" >/dev/null
	aws_route "batch-get-image:imageDigest=$DIGEST" index-nojsontype
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	staging check-build
	expect_status 0
}

@test "check-build: a version that only starts with VERSION fails (3.1.50 for 3.1.5)" {
	export VERSION=3.1.5
	good_build_routes
	go_output arm64 's/3\.1\.4/3.1.50/g'
	staging check-build
	expect_status 1
	has_line "✘ the arm64 binary's server.Version isn't 3.1.5 (ldflags: -X 'github.com/aws/secrets-store-csi-driver-provider-aws/server.Version=3.1.50' -X 'github.com/aws/secrets-store-csi-driver-provider-aws/server.ProviderVersion=3.1.50' -extldflags '-static')"
	expect_eq "$(cat "$GITHUB_OUTPUT")" ""
}

@test "check-build: only ProviderVersion wrong fails" {
	good_build_routes
	go_output amd64 's/ProviderVersion=3\.1\.4/ProviderVersion=unknown/'
	staging check-build
	expect_status 1
	has_line "✘ the amd64 binary's server.ProviderVersion isn't 3.1.4 (ldflags: -X 'github.com/aws/secrets-store-csi-driver-provider-aws/server.Version=3.1.4' -X 'github.com/aws/secrets-store-csi-driver-provider-aws/server.ProviderVersion=unknown' -extldflags '-static')"
}

@test "check-build: a missing -ldflags setting fails" {
	good_build_routes
	go_output amd64 '/-ldflags=/d'
	staging check-build
	expect_status 1
	has_line "✘ the amd64 binary has 0 -ldflags build settings, expected 1"
}

@test "check-build: CGO_ENABLED=1 fails" {
	good_build_routes
	go_output arm64 's/CGO_ENABLED=0/CGO_ENABLED=1/'
	staging check-build
	expect_status 1
	has_line "✘ the arm64 binary wasn't built with CGO_ENABLED=0"
}

@test "check-build: the wrong GOARCH fails" {
	good_build_routes
	cp "$FAKE_DIR/go-amd64.out" "$FAKE_DIR/go-arm64.out"
	staging check-build
	expect_status 1
	has_line "✘ the arm64 binary wasn't built with GOARCH=arm64"
}

@test "check-build: go version -m failing fails" {
	good_build_routes
	echo 1 >"$FAKE_DIR/go-amd64.exit"
	staging check-build
	expect_status 1
	has_line "✘ go version -m failed for the amd64 binary"
}

@test "check-build: a bad digest fails before any AWS call" {
	local bad
	for bad in "" sha256:abc "sha256:$(printf 'A%.0s' {1..64})" "sha512:$(printf 'a%.0s' {1..64})" "$DIGEST "; do
		export DIGEST=$bad
		staging check-build
		expect_status 1
	done
	expect_eq "$(count_lines "$FAKE_DIR/aws.calls")" 0
}

@test "check-build: a missing ROOTFS, or a third top-level folder, fails; etc/ inside each arch passes" {
	good_build_routes
	rm -rf "$ROOTFS"
	staging check-build
	expect_status 1
	has_line "✘ the build's local copy $ROOTFS is missing"

	make_rootfs
	mkdir -p "$ROOTFS/linux_s390x"
	staging check-build
	expect_status 1
	has_line "✘ expected exactly linux_amd64/ and linux_arm64/ in $ROOTFS, found: linux_amd64 linux_arm64 linux_s390x "

	rm -rf "$ROOTFS/linux_s390x"
	rm "$ROOTFS/linux_arm64/bin/secrets-store-csi-driver-provider-aws"
	staging check-build
	expect_status 1
	has_line "✘ linux_arm64 has no regular file at bin/secrets-store-csi-driver-provider-aws"
}

@test "check-build: the expected testing tag missing from the digest fails" {
	good_build_routes
	describe_reply digest-tags "$DIGEST"
	staging check-build
	expect_status 1
	has_line "✘ $DIGEST doesn't carry the tag rehearsal-7-testing (tags: )"
}

@test "check-build: only a different same-mode testing tag fails" {
	good_build_routes
	describe_reply digest-tags "$DIGEST" rehearsal-8-testing
	staging check-build
	expect_status 1
	has_line "✘ $DIGEST doesn't carry the tag rehearsal-7-testing (tags: rehearsal-8-testing )"
}

@test "check-build: a TESTING_TAG of the wrong shape for the mode fails" {
	export TESTING_TAG=3.1.4-testing
	staging check-build
	expect_status 1
	has_line "✘ practice run, but TESTING_TAG 3.1.4-testing is not rehearsal-<run id>-testing"
	export PRACTICE=false TESTING_TAG=rehearsal-7-testing
	staging check-build
	expect_status 1
	has_line "✘ real run, but TESTING_TAG rehearsal-7-testing is not 3.1.4-testing"
	expect_eq "$(count_lines "$FAKE_DIR/aws.calls")" 0
}

# --- practice / real separation ----------------------------------------------------------------------------------

@test "separation: a practice build whose digest has a release tag fails" {
	good_build_routes
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing 3.1.4
	staging check-build
	expect_status 1
	has_line "✘ practice run, but $DIGEST already has the release tag 3.1.4"
	has_line "  aws ecr batch-delete-image --registry-id $ACCOUNT --repository-name ascp --region us-west-2 --image-ids imageTag=3.1.4"
	expect_eq "$(cat "$GITHUB_OUTPUT")" ""
}

@test "separation: a real build whose digest has rehearsal-7 or rehearsal-7-testing fails" {
	local tag
	export PRACTICE=false TESTING_TAG=3.1.4-testing
	for tag in rehearsal-7 rehearsal-7-testing; do
		setup
		export PRACTICE=false TESTING_TAG=3.1.4-testing
		good_build_routes
		describe_reply digest-tags "$DIGEST" 3.1.4-testing "$tag"
		staging check-build
		expect_status 1
		has_line "✘ real run, but $DIGEST already has the practice tag $tag"
	done
}

@test "separation: a practice build whose digest has a release testing tag fails" {
	good_build_routes
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing 3.1.4-testing
	staging check-build
	expect_status 1
	has_line "✘ practice run, but $DIGEST already has the release tag 3.1.4-testing"
}

@test "separation: stage with an other-mode tag fails before put-image" {
	fresh_stage_routes
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing 3.1.4
	staging stage
	expect_status 1
	has_line "✘ practice run, but $DIGEST already has the release tag 3.1.4"
	expect_eq "$(calls_for put-image)" 0
}

@test "separation: stage 'already staged' plus an other-mode tag still fails" {
	export PRACTICE=false STAGE_TAG=3.1.5 TESTING_TAG=3.1.5-testing
	describe_reply digest-tags "$DIGEST" 3.1.5-testing 3.1.5 rehearsal-7
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	describe_reply tag-staged "$DIGEST" 3.1.5-testing 3.1.5 rehearsal-7
	aws_route "describe-images:imageTag=3.1.5" tag-staged
	staging stage
	expect_status 1
	has_line "✘ real run, but $DIGEST already has the practice tag rehearsal-7"
	lacks_text "already staged"
}

# --- stage -------------------------------------------------------------------------------------------------------

@test "stage: a fresh tag is added with put-image, with the exact arguments and bytes" {
	fresh_stage_routes
	staging stage
	expect_status 0
	has_line "✔ staged rehearsal-7"
	has_line "$REPO:rehearsal-7@$DIGEST"
	expect_eq "$(grep '^put-image ' "$FAKE_DIR/aws.calls")" \
		"put-image $ECR_ARGS --image-tag rehearsal-7 --image-digest $DIGEST --image-manifest file://MANIFEST --image-manifest-media-type $OCI_INDEX $TIMEOUTS | retry=standard,5"
	expect_eq "$(digest_of "$FAKE_DIR/put-image.manifest")" "${DIGEST#sha256:}"
}

@test "stage: a real run adds the version tag" {
	export PRACTICE=false STAGE_TAG=3.1.5 TESTING_TAG=3.1.5-testing
	fresh_stage_routes
	staging stage
	expect_status 0
	has_line "✔ staged 3.1.5"
}

@test "stage: already staged on the same digest passes without put-image" {
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing rehearsal-7
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	aws_route "describe-images:imageTag=rehearsal-7" digest-tags
	staging stage
	expect_status 0
	has_line "✔ rehearsal-7 is already staged at $DIGEST"
	expect_eq "$(calls_for put-image)" 0
}

@test "stage: a digest that no longer carries this run's testing tag fails without put-image" {
	# e.g. a later build of the same version moved 3.1.5-testing to its own digest
	export PRACTICE=false STAGE_TAG=3.1.5 TESTING_TAG=3.1.5-testing
	fresh_stage_routes
	describe_reply digest-tags "$DIGEST"
	staging stage
	expect_status 1
	has_line "✘ $DIGEST doesn't carry the tag 3.1.5-testing (tags: )"
	expect_eq "$(calls_for put-image)" 0
}

@test "stage: a TESTING_TAG that isn't STAGE_TAG-testing fails before any AWS call" {
	export TESTING_TAG=rehearsal-8-testing
	staging stage
	expect_status 1
	has_line "✘ TESTING_TAG rehearsal-8-testing is not rehearsal-7-testing"
	unset TESTING_TAG
	staging stage
	expect_status 1
	has_line "✘ TESTING_TAG is not set"
	expect_eq "$(count_lines "$FAKE_DIR/aws.calls")" 0
}

@test "stage: the tag on a different digest fails without put-image" {
	describe_reply digest-tags "$DIGEST" rehearsal-7-testing
	aws_route "describe-images:imageDigest=$DIGEST" digest-tags
	describe_reply other "$OTHER_DIGEST" rehearsal-7
	aws_route "describe-images:imageTag=rehearsal-7" other
	staging stage
	expect_status 1
	has_line "✘ rehearsal-7 already points at $OTHER_DIGEST, not $DIGEST"
	expect_eq "$(calls_for put-image)" 0
}

@test "stage: 'already exists' errors pass only if the tag points at our digest" {
	local error
	for error in ImageTagAlreadyExistsException ImageAlreadyExistsException; do
		setup
		fresh_stage_routes
		aws_error exists "$error" PutImage "made-up message"
		aws_route "put-image:rehearsal-7" exists
		staging stage
		expect_status 0
		has_line "✔ staged rehearsal-7"

		setup
		fresh_stage_routes
		aws_error exists "$error" PutImage "made-up message"
		aws_route "put-image:rehearsal-7" exists
		describe_reply other "$OTHER_DIGEST" rehearsal-7
		aws_route "describe-images:imageTag=rehearsal-7" tag-missing,other
		staging stage
		expect_status 1
		has_line "✘ after staging, rehearsal-7 points at $OTHER_DIGEST, not $DIGEST"
	done
}

@test "stage: another put-image error fails" {
	fresh_stage_routes
	aws_error denied AccessDeniedException PutImage "not authorized"
	aws_route "put-image:rehearsal-7" denied
	staging stage
	expect_status 1
	has_line "✘ could not add rehearsal-7 to $DIGEST (exit 254)"
}

@test "stage: the tag pointing elsewhere after put-image fails" {
	fresh_stage_routes
	describe_reply other "$OTHER_DIGEST" rehearsal-7
	aws_route "describe-images:imageTag=rehearsal-7" tag-missing,other
	staging stage
	expect_status 1
	has_line "✘ after staging, rehearsal-7 points at $OTHER_DIGEST, not $DIGEST"
}

# --- every AWS command -------------------------------------------------------------------------------------------

@test "every AWS command refuses IMAGE_REPO look-alikes" {
	local bad command
	for command in check-free login check-build stage; do
		for bad in "$REGISTRY/ascp2" "$REGISTRY/other" "$REGISTRY/ascp/x" "$REGISTRY" "x$REPO" \
			"$ACCOUNT.dkr.ecr.us-west-2.amazonaws.com.evil.example/ascp" "public.ecr.aws/ascp/ascp" "$REPO"$'\n'; do
			export IMAGE_REPO=$bad
			staging "$command"
			expect_status 1
			has_line "✘ IMAGE_REPO $(printf '%q' "$bad") is not <account>.dkr.ecr.<region>.amazonaws.com/ascp"
		done
	done
	expect_eq "$(count_lines "$FAKE_DIR/aws.calls")" 0
	expect_eq "$(count_lines "$FAKE_DIR/docker.calls")" 0
}

@test "every AWS command refuses a region that isn't the repo's" {
	local command
	export AWS_REGION=us-east-1
	for command in check-free login check-build stage; do
		staging "$command"
		expect_status 1
		has_line "✘ AWS_REGION us-east-1 is not the repo's region (us-west-2)"
	done
	expect_eq "$(count_lines "$FAKE_DIR/aws.calls")" 0
}

@test "every AWS command refuses unset retry settings" {
	local command name
	for command in check-free login check-build stage; do
		for name in AWS_RETRY_MODE AWS_MAX_ATTEMPTS; do
			setup
			unset "$name"
			staging "$command"
			expect_status 1
			has_line "✘ $name is not set"
			expect_eq "$(count_lines "$FAKE_DIR/aws.calls")" 0
		done
	done
}

@test "check-free and stage refuse bad tag shapes and a tag of the other mode" {
	local command bad
	for command in check-free stage; do
		for bad in 3.1.5 rehearsal- rehearsal-7a rehearsal-7-testing latest; do
			export PRACTICE=true STAGE_TAG=$bad
			staging "$command"
			expect_status 1
			has_line "✘ practice run, but STAGE_TAG $bad is not rehearsal-<run id>"
		done
		for bad in rehearsal-1 3.1 v3.1.5 3.1.5-testing 03.1.5; do
			export PRACTICE=false STAGE_TAG=$bad
			staging "$command"
			expect_status 1
			has_line "✘ real run, but STAGE_TAG $bad is not X.Y.Z"
		done
	done
	expect_eq "$(count_lines "$FAKE_DIR/aws.calls")" 0
}

@test "a bad PRACTICE is refused" {
	local command
	export PRACTICE=yes
	for command in check-free check-build stage; do
		staging "$command"
		expect_status 1
		has_line "✘ PRACTICE must be true or false, not yes"
	done
}

@test "an unknown command is a usage error" {
	staging publish
	expect_status 2
	staging
	expect_status 2
}

@test "the temp directory is removed after every command" {
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$TMPDIR"
	fresh_stage_routes
	staging stage
	expect_status 0
	setup
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	good_build_routes
	staging check-build
	expect_status 0
	expect_eq "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0
}
