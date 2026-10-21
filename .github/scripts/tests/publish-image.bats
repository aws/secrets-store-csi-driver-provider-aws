#!/usr/bin/env bats
#
# Tests for publish-image.sh (the Release workflow's steps that publish the tested image to ECR Public). A fake aws
# (fake-bin/) answers from per-test replies, so no test touches AWS or a registry. The account IDs are the AWS
# documentation's example accounts.

load test_helper

SCRIPT="$SCRIPTS_DIR/publish-image.sh"
STAGING_ACCOUNT=111122223333
PUBLISH_ACCOUNT=444455556666
PROD=public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws
SANDBOX=public.ecr.aws/example-sandbox/secrets-store-csi-driver-provider-aws
PULL_ARN=arn:aws:iam::$STAGING_ACCOUNT:role/ExamplePullRole
PUBLISH_ARN=arn:aws:iam::$PUBLISH_ACCOUNT:role/ExamplePublishRole
OTHER_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
TIMEOUTS="--output json --cli-read-timeout 30 --cli-connect-timeout 10"
PUBLIC_ARGS="--registry-id $PUBLISH_ACCOUNT --repository-name secrets-store-csi-driver-provider-aws --region us-east-1"

setup() {
	common_setup
	mkdir -p "$FAKE_DIR/aws"
	local file
	for file in aws.routes aws.calls aws.keys aws-public.calls order.log; do
		: >"$FAKE_DIR/$file"
	done
	export TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$TMPDIR"

	export DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333
	export PRACTICE=true PUBLIC_REPO=$SANDBOX VERSION_TAGS="rehearsal-7 rehearsal-7-linux-amd64 rehearsal-7-linux-arm64"
	export STAGING_PULL_ROLE_ARN=$PULL_ARN PUBLISH_ROLE_ARN=$PUBLISH_ARN
	export PUBLISH_ACCOUNT_ID=$PUBLISH_ACCOUNT AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=5
	export AWS_ACCESS_KEY_ID=AKIAPUBLISHMARKER AWS_SECRET_ACCESS_KEY=SECRETPUBLISHMARKER
	export AWS_SESSION_TOKEN=TOKENPUBLISHMARKER
	export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	common_teardown
}

publish() {
	run bash "$SCRIPT" "$@"
}

# The three version tags, in order.
tags() { echo "$VERSION_TAGS"; }

real_run() {
	export PRACTICE=false PUBLIC_REPO=$PROD VERSION_TAGS="3.1.5 3.1.5-linux-amd64 3.1.5-linux-arm64"
}

# --- fake aws replies --------------------------------------------------------------------------------------------

# aws_route <key> <reply>[,<reply>...] : replaces any earlier route for the key.
aws_route() {
	local routes="$FAKE_DIR/aws.routes"
	awk -v key="$1" '$1 != key' "$routes" >"$routes.new"
	echo "$1 $2" >>"$routes.new"
	mv "$routes.new" "$routes"
}

aws_reply() { printf '%s\n' "$2" >"$FAKE_DIR/aws/$1.out"; }

# aws_error <name> <ErrorName> <Operation> <message> : a service error in the recorded CLI v2 format, exit 254.
aws_error() {
	printf '\naws: [ERROR]: An error occurred (%s) when calling the %s operation: %s\n' "$2" "$3" "$4" \
		>"$FAKE_DIR/aws/$1.err"
	echo 254 >"$FAKE_DIR/aws/$1.exit"
}

# public_found <name> <digest> : ecr-public describe-images finds one image with that digest.
public_found() {
	aws_reply "$1" "$(jq -n --arg d "$2" --arg a "$PUBLISH_ACCOUNT" '
		{imageDetails: [{registryId: $a, repositoryName: "secrets-store-csi-driver-provider-aws", imageDigest: $d,
			imageTags: ["some-tag"], imageSizeInBytes: 1607,
			imageManifestMediaType: "application/vnd.oci.image.index.v1+json"}]}')"
}

# The replies every test can name: absent, ours (DIGEST) and foreign (OTHER_DIGEST).
public_replies() {
	aws_error absent ImageNotFoundException DescribeImages \
		"The image with imageId {imageDigest:'null', imageTag:'x'} does not exist within the repository"
	public_found ours "$DIGEST"
	public_found foreign "$OTHER_DIGEST"
}

# tag_route <tag> <reply> : the reply to describe-images for one public tag.
tag_route() { aws_route "public:describe-images:imageTag=$1" "$2"; }

public_describes() { grep -c "^ecr-public describe-images " "$FAKE_DIR/aws-public.calls" || true; }

# --- no-env-credentials ------------------------------------------------------------------------------------------

@test "no-env-credentials: passes with no AWS keys in the environment" {
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
	publish no-env-credentials
	expect_status 0
	has_line "✔ no AWS credentials in the job environment"
}

@test "no-env-credentials: each AWS key, even empty, fails" {
	local name
	for name in AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
		unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
		export "$name="
		publish no-env-credentials
		expect_status 1
		has_line "✘ $name is set in the job environment"
		has_line "✘ AWS credentials must reach steps only through step outputs (check output-env-credentials)"
	done
}

# --- role-accounts -----------------------------------------------------------------------------------------------

@test "role-accounts: writes both accounts" {
	publish role-accounts
	expect_status 0
	expect_eq "$(cat "$GITHUB_OUTPUT")" "publishAccountId=$PUBLISH_ACCOUNT
pullAccountId=$STAGING_ACCOUNT"
	has_line "✔ publish role in account $PUBLISH_ACCOUNT, pull role in account $STAGING_ACCOUNT"
	expect_eq "$(count_lines "$FAKE_DIR/order.log")" 0
}

@test "role-accounts: anything but a role ARN is refused and nothing is written" {
	local arn name
	for name in PUBLISH_ROLE_ARN STAGING_PULL_ROLE_ARN; do
		for arn in "" "arn:aws:iam::$PUBLISH_ACCOUNT:user/someone" "arn:aws-cn:iam::$PUBLISH_ACCOUNT:role/x" \
			"arn:aws:iam::12345:role/x" "arn:aws:sts::$PUBLISH_ACCOUNT:assumed-role/x/y" \
			"arn:aws:iam::$PUBLISH_ACCOUNT:role/" "arn:aws:iam::$PUBLISH_ACCOUNT:role/x
y" " arn:aws:iam::$PUBLISH_ACCOUNT:role/x"; do
			setup
			export "$name=$arn"
			publish role-accounts
			expect_status 1
			lacks_text "✔"
			expect_eq "$(cat "$GITHUB_OUTPUT")" ""
		done
	done
}

# --- precheck-version-tags ---------------------------------------------------------------------------------------

@test "precheck: every tag free passes, after reading all three, with the publish credentials" {
	local tag
	public_replies
	for tag in $(tags); do
		tag_route "$tag" absent
	done
	publish precheck-version-tags
	expect_status 0
	has_line "✔ target $SANDBOX (practice run, not the production repo)"
	has_line "✔ rehearsal-7 is free"
	has_line "✔ rehearsal-7-linux-amd64 is free"
	has_line "✔ rehearsal-7-linux-arm64 is free"
	has_line "✔ all version tags are free or already on $DIGEST"
	expect_eq "$(cat "$FAKE_DIR/aws-public.calls")" "ecr-public describe-images $PUBLIC_ARGS --image-ids imageTag=rehearsal-7 $TIMEOUTS | retry=standard,5
ecr-public describe-images $PUBLIC_ARGS --image-ids imageTag=rehearsal-7-linux-amd64 $TIMEOUTS | retry=standard,5
ecr-public describe-images $PUBLIC_ARGS --image-ids imageTag=rehearsal-7-linux-arm64 $TIMEOUTS | retry=standard,5"
	expect_eq "$(awk '{ print $NF }' "$FAKE_DIR/order.log" | sort -u)" "key=AKIAPUBLISHMARKER"
	expect_eq "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0
}

@test "precheck: tags already on the build digest pass (a re-run)" {
	public_replies
	tag_route rehearsal-7 ours
	tag_route rehearsal-7-linux-amd64 absent
	tag_route rehearsal-7-linux-arm64 ours
	publish precheck-version-tags
	expect_status 0
	has_line "✔ rehearsal-7 already points at $DIGEST"
	has_line "✔ rehearsal-7-linux-amd64 is free"
	has_line "✔ rehearsal-7-linux-arm64 already points at $DIGEST"
}

@test "precheck: a tag on another digest fails, whichever tag it is, after reading all three" {
	local foreign tag i
	for foreign in 1 2 3; do
		setup
		public_replies
		i=0
		for tag in $(tags); do
			i=$((i + 1))
			if ((i == foreign)); then
				tag_route "$tag" foreign
			else
				tag_route "$tag" absent
			fi
		done
		publish precheck-version-tags
		expect_status 1
		tag=$(tags | cut -d' ' -f"$foreign")
		has_line "✘ $tag already points at $OTHER_DIGEST, not $DIGEST"
		has_line "✘ nothing was written; public tags can't be moved by this workflow, so start a new practice run"
		lacks_text "✔ all version tags"
		expect_eq "$(public_describes)" 3
	done
}

@test "precheck: any other error fails, never 'free'" {
	aws_error denied AccessDeniedException DescribeImages "User is not authorized to perform ecr-public:DescribeImages"
	tag_route rehearsal-7 denied
	publish precheck-version-tags
	expect_status 1
	has_line "✘ could not read rehearsal-7 in $SANDBOX (exit 254)"
	lacks_text "free"
	expect_eq "$(public_describes)" 1
}

@test "precheck: a target of the wrong mode is refused before any AWS call" {
	export PUBLIC_REPO=$PROD
	publish precheck-version-tags
	expect_status 1
	has_line "✘ a practice run must not publish to the production repo $PROD"
	expect_eq "$(count_lines "$FAKE_DIR/order.log")" 0

	setup
	real_run
	export PUBLIC_REPO=$SANDBOX
	publish precheck-version-tags
	expect_status 1
	has_line "✘ a real run must publish to $PROD, not $SANDBOX"
	expect_eq "$(count_lines "$FAKE_DIR/order.log")" 0
}

# --- every command -----------------------------------------------------------------------------------------------

@test "an unknown command is a usage error that lists only the publish commands" {
	publish verify
	expect_status 2
	expect_eq "$output" "usage: $SCRIPT no-env-credentials | role-accounts | precheck-version-tags"
	publish
	expect_status 2
}
