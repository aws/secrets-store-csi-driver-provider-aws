#!/usr/bin/env bats
#
# Tests for publish-image.sh (the Release workflow's steps that publish the tested image to ECR Public). Fake aws
# and crane (fake-bin/) answer from per-test replies, so no test touches AWS or a registry. The account IDs
# are the AWS documentation's example accounts.

load test_helper

SCRIPT="$SCRIPTS_DIR/publish-image.sh"
STAGING_ACCOUNT=111122223333
PUBLISH_ACCOUNT=444455556666
STAGING_REGISTRY=$STAGING_ACCOUNT.dkr.ecr.us-west-2.amazonaws.com
STAGING_REPO=$STAGING_REGISTRY/ascp
PROD=public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws
SANDBOX=public.ecr.aws/example-sandbox/secrets-store-csi-driver-provider-aws
PULL_ARN=arn:aws:iam::$STAGING_ACCOUNT:role/ExamplePullRole
PUBLISH_ARN=arn:aws:iam::$PUBLISH_ACCOUNT:role/ExamplePublishRole
OTHER_DIGEST=sha256:1111111111111111111111111111111111111111111111111111111111111111
TIMEOUTS="--output json --cli-read-timeout 30 --cli-connect-timeout 10"
PUBLIC_ARGS="--registry-id $PUBLISH_ACCOUNT --repository-name secrets-store-csi-driver-provider-aws --region us-east-1"
LABEL=com.amazonaws.secrets-store-csi-driver-provider-aws.release.mode

setup() {
	common_setup
	mkdir -p "$FAKE_DIR/aws" "$FAKE_DIR/crane"
	local file
	for file in aws.routes aws.calls aws.keys aws-public.calls order.log crane.routes crane.calls crane.keys \
		crane.docker-config; do
		: >"$FAKE_DIR/$file"
	done
	export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$RUNNER_TEMP" "$HOME" "$TMPDIR"
	unset DOCKER_CONFIG

	# The recorded public 3.1.4 index without its 2 attestation entries: the 2-platform index the build pushes.
	GOOD_INDEX="$BATS_TEST_TMPDIR/good-index.json"
	jq -c '.manifests |= map(select(.platform.os != "unknown"))' "$FIXTURES/index-public-3.1.4.json" |
		tr -d '\n' >"$GOOD_INDEX"
	export DIGEST="sha256:$(digest_of "$GOOD_INDEX")"

	export PRACTICE=true PUBLIC_REPO=$SANDBOX VERSION_TAGS="rehearsal-7 rehearsal-7-linux-amd64 rehearsal-7-linux-arm64"
	export IMAGE_REPO=$STAGING_REPO STAGING_PULL_ROLE_ARN=$PULL_ARN PUBLISH_ROLE_ARN=$PUBLISH_ARN
	export PUBLISH_ACCOUNT_ID=$PUBLISH_ACCOUNT AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=5 REGISTRY_RETRY_SCALE=0
	export AWS_ACCESS_KEY_ID=AKIAPUBLISHMARKER AWS_SECRET_ACCESS_KEY=SECRETPUBLISHMARKER
	export AWS_SESSION_TOKEN=TOKENPUBLISHMARKER
	export GITHUB_REPOSITORY=aws/secrets-store-csi-driver-provider-aws GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1
	export GITHUB_OUTPUT="$BATS_TEST_TMPDIR/github_output"
	: >"$GITHUB_OUTPUT"
}

teardown() {
	common_teardown
}

publish() {
	run bash "$SCRIPT" "$@"
}

digest_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
}

has_text() {
	if [[ "$output" != *"$1"* ]]; then
		printf 'missing text: %s\noutput:\n%s\n' "$1" "$output"
		return 1
	fi
}

# The three version tags, in order.
tags() { echo "$VERSION_TAGS"; }

real_run() {
	export PRACTICE=false PUBLIC_REPO=$PROD VERSION_TAGS="3.1.5 3.1.5-linux-amd64 3.1.5-linux-arm64"
	export STAGING_PULL_ROLE_ARN=arn:aws:iam::$STAGING_ACCOUNT:role/ExampleProdPullRole
}

# --- fake aws replies --------------------------------------------------------------------------------------------

# set_route <aws|crane> <key> <reply>[,<reply>...] : replaces any earlier route for the key in that fake's routes.
set_route() {
	local routes="$FAKE_DIR/$1.routes"
	awk -v key="$2" '$1 != key' "$routes" >"$routes.new"
	echo "$2 $3" >>"$routes.new"
	mv "$routes.new" "$routes"
}

aws_route() { set_route aws "$@"; }

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

# tag_route <tag> <reply>[,<reply>...] : the replies to describe-images for one public tag, in call order.
tag_route() { aws_route "public:describe-images:imageTag=$1" "$2"; }

# staging_tags <tag>... : the staging repo's describe-images by DIGEST finds these tags on it.
staging_tags() {
	aws_reply staging-digest "$(jq -n --arg d "$DIGEST" --arg a "$STAGING_ACCOUNT" '
		{imageDetails: [{registryId: $a, repositoryName: "ascp", imageDigest: $d, imageTags: $ARGS.positional,
			imageManifestMediaType: "application/vnd.oci.image.index.v1+json"}]}' --args "$@")"
	aws_route "describe-images:imageDigest=$DIGEST" staging-digest
}

# pull_credentials : the assume-role reply, with marker values.
pull_credentials() {
	aws_reply pull-creds "$(jq -n --arg arn "arn:aws:sts::$STAGING_ACCOUNT:assumed-role/ExamplePullRole/ascp-publish-7-1" '
		{Credentials: {AccessKeyId: "AKIAPULLMARKER", SecretAccessKey: "SECRETPULLMARKER",
			SessionToken: "TOKENPULLMARKER", Expiration: "2026-10-17T20:00:00+00:00"},
		AssumedRoleUser: {AssumedRoleId: "AROAEXAMPLE:ascp-publish-7-1", Arn: $arn}}')"
	aws_route sts:assume-role pull-creds
}

# --- fake crane replies ------------------------------------------------------------------------------------------

crane_route() { set_route crane "$@"; }

# crane_config <mode label value> : both platforms' image configs carry this mode label ("" for none).
crane_config() {
	if [[ -n "$1" ]]; then
		jq -n --arg k "$LABEL" --arg v "$1" '{architecture: "amd64", os: "linux", config: {Labels: {($k): $v}}}' \
			>"$FAKE_DIR/crane/config.out"
	else
		jq -n '{architecture: "amd64", os: "linux", config: {}}' >"$FAKE_DIR/crane/config.out"
	fi
	crane_route config:linux/amd64 config
	crane_route config:linux/arm64 config
}

# Routes for a run that passes: the pull role, both logins, the mode check, crane writes that succeed, and the
# published manifest that is the good index. Every version tag is absent, then reads back as ours.
good_routes() {
	local tag mode=practice stage_tag
	stage_tag=${VERSION_TAGS%% *}
	if [[ "$PRACTICE" == false ]]; then
		mode=real
	fi
	public_replies
	pull_credentials
	aws_reply pull-password PULLPASSWORDMARKER
	aws_route get-login-password pull-password
	aws_reply public-password PUBLICPASSWORDMARKER
	aws_route public:get-login-password public-password
	staging_tags "$stage_tag-testing" "$stage_tag"
	crane_config "$mode"
	: >"$FAKE_DIR/crane/ok.out"
	for tag in $(tags); do
		tag_route "$tag" absent,ours
		crane_route "copy:$tag" ok
	done
	cp "$GOOD_INDEX" "$FAKE_DIR/crane/manifest.out"
	crane_route manifest manifest
}

# --- call logs ---------------------------------------------------------------------------------------------------

# The crane writes (copies), as "copy <tag>".
crane_writes() {
	awk '$1 == "copy" { n = split($3, a, ":"); print "copy " a[n] }' "$FAKE_DIR/crane.calls"
}

public_describes() { grep -c "^ecr-public describe-images " "$FAKE_DIR/aws-public.calls" || true; }
describes_of() { grep -c "^ecr-public describe-images .* imageTag=$1 " "$FAKE_DIR/aws-public.calls" || true; }

# order.log, one short line per call: "aws <service> <operation> [image id] key=<key>" or "crane <sub> <last arg>".
order_summary() {
	awk '
		$1 == "aws" {
			id = ""
			for (i = 4; i <= NF; i++) if ($i ~ /^image(Tag|Digest)=/) id = " " $i
			print "aws " $2 " " $3 id " " $NF
			next
		}
		$1 == "crane" && $2 == "auth" { print "crane login " $4; next }
		$1 == "crane" { print "crane " $2 " " $NF }
	' "$FAKE_DIR/order.log"
}

# No temporary DOCKER_CONFIG left, nothing in ~/.docker, and no temp directory left.
expect_clean() {
	expect_eq "$(find "$RUNNER_TEMP" -mindepth 1 -maxdepth 1 -name 'dc.*' | wc -l | tr -d ' ')" 0
	expect_eq "$(find "$TMPDIR" -mindepth 1 | wc -l | tr -d ' ')" 0
	if [[ -e "$HOME/.docker" ]]; then
		echo "~/.docker was written"
		return 1
	fi
}

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
	expect_eq "$(order_summary | awk '{ print $NF }' | sort -u)" "key=AKIAPUBLISHMARKER"
	expect_eq "$(count_lines "$FAKE_DIR/crane.calls")" 0
	expect_clean
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

# --- copy-version-tags -------------------------------------------------------------------------------------------

@test "copy: a fresh practice run copies all three tags from staging in the fixed order and reads each one back" {
	good_routes
	publish copy-version-tags
	expect_status 0
	has_line "✔ assumed the pull role in account $STAGING_ACCOUNT"
	has_line "✔ $STAGING_REPO@$DIGEST is staged as rehearsal-7 and has no tags of the other mode"
	has_line "✔ both images are labelled $LABEL=practice"
	has_line "✔ platforms: linux/amd64 linux/arm64"
	has_line "✔ published $SANDBOX@$DIGEST as rehearsal-7 rehearsal-7-linux-amd64 rehearsal-7-linux-arm64"
	expect_eq "$(cat "$GITHUB_OUTPUT")" "publicRepo=$SANDBOX"
	expect_clean
	# Each aws call runs with the right role's credentials. The mode check comes after the staging login it
	# needs and before the first public write; each tag is re-checked right before its write and read back after.
	expect_eq "$(order_summary)" "aws sts assume-role key=AKIAPUBLISHMARKER
aws ecr get-login-password key=AKIAPULLMARKER
crane login $STAGING_REGISTRY
aws ecr-public get-login-password key=AKIAPUBLISHMARKER
crane login public.ecr.aws
aws ecr describe-images imageDigest=$DIGEST key=AKIAPULLMARKER
crane config $STAGING_REPO@$DIGEST
crane config $STAGING_REPO@$DIGEST
aws ecr-public describe-images imageTag=rehearsal-7 key=AKIAPUBLISHMARKER
crane copy $SANDBOX:rehearsal-7
aws ecr-public describe-images imageTag=rehearsal-7 key=AKIAPUBLISHMARKER
aws ecr-public describe-images imageTag=rehearsal-7-linux-amd64 key=AKIAPUBLISHMARKER
crane copy $SANDBOX:rehearsal-7-linux-amd64
aws ecr-public describe-images imageTag=rehearsal-7-linux-amd64 key=AKIAPUBLISHMARKER
aws ecr-public describe-images imageTag=rehearsal-7-linux-arm64 key=AKIAPUBLISHMARKER
crane copy $SANDBOX:rehearsal-7-linux-arm64
aws ecr-public describe-images imageTag=rehearsal-7-linux-arm64 key=AKIAPUBLISHMARKER
crane manifest $SANDBOX@$DIGEST"
}

@test "copy: every mix of absent and already-published tags writes only the absent ones (re-runs)" {
	local states state tag expected i
	for states in "absent absent absent" "ours absent absent" "absent ours absent" "absent absent ours" \
		"ours ours absent" "ours absent ours" "absent ours ours" "ours ours ours"; do
		setup
		good_routes
		expected="" i=0
		for state in $states; do
			i=$((i + 1))
			tag=$(tags | cut -d' ' -f"$i")
			if [[ "$state" == ours ]]; then
				tag_route "$tag" ours
			else
				expected="$expected${expected:+$'\n'}copy $tag"
			fi
		done
		publish copy-version-tags
		expect_status 0
		expect_eq "$(crane_writes)" "$expected"
		expect_eq "$(cat "$GITHUB_OUTPUT")" "publicRepo=$SANDBOX"
		expect_clean
	done
}

@test "copy: a tag on another digest at its re-check stops the run before that write" {
	good_routes
	tag_route rehearsal-7-linux-amd64 foreign
	publish copy-version-tags
	expect_status 1
	has_line "✘ rehearsal-7-linux-amd64 now points at $OTHER_DIGEST, not $DIGEST; stopping"
	expect_eq "$(crane_writes)" "copy rehearsal-7"
	expect_eq "$(describes_of rehearsal-7-linux-arm64)" 0
	expect_eq "$(cat "$GITHUB_OUTPUT")" ""
	expect_clean
}

@test "copy: a foreign digest on read-back aborts at once, with no retry and no further write" {
	good_routes
	tag_route rehearsal-7 absent,foreign,ours
	publish copy-version-tags
	expect_status 1
	has_line "✘ after the write, rehearsal-7 points at $OTHER_DIGEST, not $DIGEST; stopping"
	expect_eq "$(describes_of rehearsal-7)" 2
	expect_eq "$(crane_writes)" "copy rehearsal-7"
	expect_eq "$(cat "$GITHUB_OUTPUT")" ""
	expect_clean
}

@test "copy: a write that never becomes visible fails closed after 6 reads" {
	good_routes
	tag_route rehearsal-7 absent
	publish copy-version-tags
	expect_status 1
	has_line "✘ write not visible after 6 attempts: rehearsal-7 still reads as absent, not $DIGEST"
	expect_eq "$(describes_of rehearsal-7)" 7
	expect_eq "$(crane_writes)" "copy rehearsal-7"
	expect_clean
}

@test "copy: a real run refuses a digest with a rehearsal tag, before any public write" {
	local tag
	for tag in rehearsal-7 rehearsal-7-testing; do
		setup
		real_run
		good_routes
		staging_tags 3.1.5-testing 3.1.5 "$tag"
		publish copy-version-tags
		expect_status 1
		has_line "✘ real run, but $STAGING_REPO@$DIGEST has the practice tag $tag"
		expect_eq "$(crane_writes)" ""
		expect_eq "$(public_describes)" 0
		expect_clean
	done
}

@test "copy: the mode label must match the run's mode" {
	local label
	for label in real "" Practice; do
		setup
		good_routes
		crane_config "$label"
		publish copy-version-tags
		expect_status 1
		has_text "✘ practice run, but the linux/amd64 image's $LABEL label is"
		expect_eq "$(crane_writes)" ""
	done
}

@test "copy: the pull credentials appear in the output only in ::add-mask:: lines; passwords never" {
	local line
	good_routes
	publish copy-version-tags
	expect_status 0
	while IFS= read -r line; do
		if [[ "$line" == *MARKER* && "$line" != "::add-mask::"* ]]; then
			echo "a credential marker outside an ::add-mask:: line: $line"
			return 1
		fi
	done <<<"$output"
	has_line "::add-mask::AKIAPULLMARKER"
	has_line "::add-mask::SECRETPULLMARKER"
	has_line "::add-mask::TOKENPULLMARKER"
	lacks_text PASSWORDMARKER
	lacks_text PUBLISHMARKER
}

@test "copy: DOCKER_CONFIG is removed when a login fails" {
	good_routes
	echo "Error: invalid username/password" >"$FAKE_DIR/crane/bad-login.err"
	echo 1 >"$FAKE_DIR/crane/bad-login.exit"
	crane_route login:public.ecr.aws bad-login
	publish copy-version-tags
	expect_status 1
	has_line "✘ could not log in to public.ecr.aws (exit 1)"
	expect_eq "$(crane_writes)" ""
	expect_clean
}

# --- every command -----------------------------------------------------------------------------------------------

@test "an unknown command is a usage error that lists only the publish commands" {
	publish verify
	expect_status 2
	expect_eq "$output" "usage: $SCRIPT no-env-credentials | role-accounts | precheck-version-tags | copy-version-tags"
	publish
	expect_status 2
}
