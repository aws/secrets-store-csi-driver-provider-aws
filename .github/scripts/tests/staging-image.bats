#!/usr/bin/env bats
#
# Tests for staging-image.sh (the Release workflow's steps against the private staging repo). Fake aws and docker
# (fake-bin/) answer from per-test replies, so no test touches AWS or a registry.

load test_helper

SCRIPT="$SCRIPTS_DIR/staging-image.sh"
ACCOUNT=123456789012
REGISTRY=$ACCOUNT.dkr.ecr.us-west-2.amazonaws.com
REPO=$REGISTRY/ascp
TIMEOUTS="--output json --cli-read-timeout 30 --cli-connect-timeout 10"
ECR_ARGS="--registry-id $ACCOUNT --repository-name ascp --region us-west-2"

setup() {
	common_setup
	mkdir -p "$FAKE_DIR/aws"
	: >"$FAKE_DIR/aws.routes"
	: >"$FAKE_DIR/aws.calls"
	: >"$FAKE_DIR/aws.keys"
	: >"$FAKE_DIR/docker.calls"
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
	export DIGEST="sha256:$(printf 'd%.0s' {1..64})"

	export IMAGE_REPO=$REPO AWS_REGION=us-west-2 AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=5
	export PRACTICE=true STAGE_TAG=rehearsal-7
}

teardown() {
	common_teardown
}

staging() {
	run bash "$SCRIPT" "$@"
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

not_found() {
	aws_error "$1" ImageNotFoundException DescribeImages \
		"The image with imageId {imageDigest:'null', imageTag:'$STAGE_TAG'} does not exist within the repository with name 'ascp' in the registry with id '$ACCOUNT'"
}

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
	export PRACTICE=false STAGE_TAG=3.1.5
	describe_reply found "$DIGEST" 3.1.5 3.1.5-testing
	aws_route "describe-images:imageTag=3.1.5" found
	staging check-free
	expect_status 1
	has_line "✘ 3.1.5 is already staged (at $DIGEST); tags there are permanent, so re-run the failed jobs of the run that staged it, or release a new version"
}

@test "check-free: any other error fails, never 'free'" {
	aws_error denied AccessDeniedException DescribeImages "User is not authorized to perform: ecr:DescribeImages"
	aws_route "describe-images:imageTag=rehearsal-7" denied
	staging check-free
	expect_status 1
	has_line "✘ could not check rehearsal-7 (exit 254)"
	lacks_text "is free"
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

@test "logout: logs out of the registry" {
	echo "$REGISTRY" >"$FAKE_DIR/docker.logged-in"
	staging logout
	expect_status 0
	has_line "Removing login credentials for $REGISTRY"
	expect_eq "$(cat "$FAKE_DIR/docker.calls")" "logout $REGISTRY"
}

# --- every AWS command -------------------------------------------------------------------------------------------

@test "every AWS command refuses IMAGE_REPO look-alikes" {
	local bad command
	for command in check-free login; do
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

@test "check-free refuses bad tag shapes and a tag of the other mode" {
	local command bad
	for command in check-free; do
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
