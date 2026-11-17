#!/usr/bin/env bats
#
# Tests for sign-image.sh (the Release workflow's cosign signing). Fake cosign, aws and curl (fake-bin/) answer from
# per-test replies, so no test touches AWS, a registry or Sigstore.

load test_helper

SCRIPT="$SCRIPTS_DIR/sign-image.sh"
PROD=public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws
SANDBOX=public.ecr.aws/example-sandbox/secrets-store-csi-driver-provider-aws
DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333
WORKFLOW=aws/secrets-store-csi-driver-provider-aws/.github/workflows/release.yml
MAIN_IDENTITY=https://github.com/$WORKFLOW@refs/heads/main
COSIGN_AMD64_URL=https://github.com/sigstore/cosign/releases/download/v3.1.4/cosign-linux-amd64
COSIGN_ARM64_URL=https://github.com/sigstore/cosign/releases/download/v3.1.4/cosign-linux-arm64

setup() {
	common_setup
	mkdir -p "$FAKE_DIR/aws"
	local file
	for file in aws.routes aws.calls aws.keys aws-public.calls order.log cosign.routes cosign.calls cosign.hanging; do
		: >"$FAKE_DIR/$file"
	done
	export RUNNER_TEMP="$BATS_TEST_TMPDIR/runner-temp" HOME="$BATS_TEST_TMPDIR/home" TMPDIR="$BATS_TEST_TMPDIR/tmp"
	mkdir -p "$RUNNER_TEMP" "$HOME" "$TMPDIR"
	unset DOCKER_CONFIG
	export PRACTICE=true PUBLIC_REPO=$SANDBOX DIGEST GITHUB_WORKFLOW_REF=$WORKFLOW@refs/heads/main
	export AWS_RETRY_MODE=standard AWS_MAX_ATTEMPTS=5 SIGN_RETRY_SCALE=0
	export AWS_ACCESS_KEY_ID=AKIAPUBLISHMARKER AWS_SECRET_ACCESS_KEY=SECRETPUBLISHMARKER
	export AWS_SESSION_TOKEN=TOKENPUBLISHMARKER
	export ACTIONS_ID_TOKEN_REQUEST_URL=https://token.example ACTIONS_ID_TOKEN_REQUEST_TOKEN=REQUESTTOKENMARKER
	export GITHUB_PATH="$BATS_TEST_TMPDIR/github_path" RUNNER_ARCH=X64
	: >"$GITHUB_PATH"
	printf '%s\n' PUBLICPASSWORDMARKER >"$FAKE_DIR/aws/public-password.out"
	echo "public:get-login-password public-password" >"$FAKE_DIR/aws.routes"
}

teardown() {
	common_teardown
}

sign() { run bash "$SCRIPT" "$@"; }

cosign_route() { echo "$1 $2" >>"$FAKE_DIR/cosign.routes"; }

# For verify: the job has no AWS credentials and no instance metadata.
no_credentials() {
	unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
	export AWS_EC2_METADATA_DISABLED=true
}

digest_of() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{ print $1 }'
	else
		shasum -a 256 "$1" | awk '{ print $1 }'
	fi
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

# --- sign --------------------------------------------------------------------------------------------------------

@test "sign: logs in with the publish role, signs the digest, then checks the signature" {
	cosign_route verify 1,0
	sign sign
	expect_status 0
	has_line "✔ logged in to public.ecr.aws (publish role)"
	has_line "✔ signed $SANDBOX@$DIGEST as https://github.com/$WORKFLOW@refs/heads/main"
	expect_eq "$(cat "$FAKE_DIR/cosign-login")" PUBLICPASSWORDMARKER
	expect_eq "$(cat "$FAKE_DIR/cosign.calls")" "login public.ecr.aws -u AWS --password-stdin
verify --certificate-identity $MAIN_IDENTITY --certificate-oidc-issuer https://token.actions.githubusercontent.com $SANDBOX@$DIGEST
sign --yes --oidc-provider github-actions $SANDBOX@$DIGEST
verify --certificate-identity $MAIN_IDENTITY --certificate-oidc-issuer https://token.actions.githubusercontent.com $SANDBOX@$DIGEST"
	# The login comes from the publish role's keys; every cosign call after it uses that login.
	expect_eq "$(grep -c 'ecr-public get-login-password --region us-east-1 --cli-read-timeout 30 --cli-connect-timeout 10 | key=AKIAPUBLISHMARKER$' "$FAKE_DIR/order.log")" 1
	expect_eq "$(grep '^cosign ' "$FAKE_DIR/order.log" | awk '{ print $2, $NF }')" "login login=no
verify login=yes
sign login=yes
verify login=yes"
	lacks_text PUBLICPASSWORDMARKER
	lacks_text SECRETPUBLISHMARKER
	expect_clean
}

@test "sign: a real run signs the production repo as release.yml on main" {
	export PRACTICE=false PUBLIC_REPO=$PROD
	cosign_route verify 1,0
	sign sign
	expect_status 0
	has_line "✔ target $PROD (real run, the production repo)"
	has_line "✔ signed $PROD@$DIGEST as $MAIN_IDENTITY"
	expect_eq "$(grep -c "^sign --yes --oidc-provider github-actions $PROD@$DIGEST$" "$FAKE_DIR/cosign.calls")" 1
	expect_clean
}

@test "sign: a practice run on another branch signs as that branch" {
	export GITHUB_WORKFLOW_REF=$WORKFLOW@refs/heads/try/sign
	cosign_route verify 1,0
	sign sign
	expect_status 0
	has_line "✔ signed $SANDBOX@$DIGEST as https://github.com/$WORKFLOW@refs/heads/try/sign"
	expect_clean
}

@test "sign: an image already signed by this workflow (a re-run) is not signed again" {
	sign sign
	expect_status 0
	has_line "✔ $SANDBOX@$DIGEST is already signed by $MAIN_IDENTITY"
	expect_eq "$(grep -c '^sign ' "$FAKE_DIR/cosign.calls" || true)" 0
	expect_clean
}

@test "sign: a failed signing fails with cosign's output" {
	cosign_route verify 1
	cosign_route sign 1
	sign sign
	expect_status 1
	has_line "  made-up cosign sign error"
	has_line "✘ could not sign $SANDBOX@$DIGEST (cosign exit 1)"
	expect_clean
}

@test "sign: a signature that doesn't show up at once is read again after signing" {
	cosign_route verify 1,1,1,0
	sign sign
	expect_status 0
	has_line "  no signature from $MAIN_IDENTITY yet (attempt 1 of 4); reading again"
	has_line "  no signature from $MAIN_IDENTITY yet (attempt 2 of 4); reading again"
	has_line "✔ signed $SANDBOX@$DIGEST as $MAIN_IDENTITY"
	# One check before signing, then three after it.
	expect_eq "$(grep -c '^verify ' "$FAKE_DIR/cosign.calls")" 4
	expect_eq "$(grep -c '^sign ' "$FAKE_DIR/cosign.calls")" 1
	expect_clean
}

@test "sign: a signature that does not verify after signing fails after 4 reads" {
	cosign_route verify 1
	sign sign
	expect_status 1
	has_line "  made-up cosign verify error"
	has_line "✘ signed $SANDBOX@$DIGEST, but its signature does not verify as $MAIN_IDENTITY (checked 4 times)"
	expect_eq "$(grep -c '^verify ' "$FAKE_DIR/cosign.calls")" 5
	expect_clean
}

@test "sign: a failed login fails before any signing" {
	cosign_route login 1
	sign sign
	expect_status 1
	has_line "✘ could not log in to public.ecr.aws (exit 1)"
	expect_eq "$(grep -cE '^(verify|sign) ' "$FAKE_DIR/cosign.calls" || true)" 0
	expect_clean
}

@test "sign: a failed ECR Public password request fails before any signing" {
	printf '\naws: [ERROR]: An error occurred (AccessDeniedException) when calling the GetAuthorizationToken operation: made up\n' \
		>"$FAKE_DIR/aws/public-password.err"
	echo 254 >"$FAKE_DIR/aws/public-password.exit"
	sign sign
	expect_status 1
	has_line "  aws: [ERROR]: An error occurred (AccessDeniedException) when calling the GetAuthorizationToken operation: made up"
	has_line "✘ could not log in to public.ecr.aws (exit 254)"
	expect_eq "$(grep -cE '^(verify|sign) ' "$FAKE_DIR/cosign.calls" || true)" 0
	expect_clean
}

@test "sign: a cancelled job (TERM or HUP) still removes the temporary login" {
	local signal pid code attempt
	for signal in TERM:143 HUP:129; do
		setup
		cosign_route verify 1
		cosign_route sign hang
		bash "$SCRIPT" sign >"$BATS_TEST_TMPDIR/out" 2>&1 &
		pid=$!
		for attempt in $(seq 100); do
			if [[ -s "$FAKE_DIR/cosign.hanging" ]]; then
				break
			fi
			sleep 0.1
		done
		if [[ ! -s "$FAKE_DIR/cosign.hanging" ]]; then
			echo "cosign sign never started"
			kill "$pid" || true
			return 1
		fi
		# The runner signals the whole job: the script, then cosign.
		kill -"${signal%%:*}" "$pid"
		kill -TERM "$(cat "$FAKE_DIR/cosign.hanging")"
		code=0
		wait "$pid" || code=$?
		expect_eq "$code" "${signal#*:}"
		expect_clean
	done
}

@test "sign: a real run that isn't release.yml on main fails before any call" {
	local ref
	export PRACTICE=false PUBLIC_REPO=$PROD
	for ref in "$WORKFLOW@refs/heads/try/sign" "$WORKFLOW@refs/tags/3.1.5" \
		"aws/secrets-store-csi-driver-provider-aws/.github/workflows/integ.yml@refs/heads/main" \
		"someone/fork/.github/workflows/release.yml@refs/heads/main"; do
		export GITHUB_WORKFLOW_REF=$ref
		sign sign
		expect_status 1
		has_line "✘ a real run must be $WORKFLOW on main, not $ref"
		expect_eq "$(count_lines "$FAKE_DIR/order.log")" 0
	done
	expect_clean
}

@test "sign: a practice run that isn't release.yml in this repo on a branch fails before any call" {
	local ref
	for ref in "$WORKFLOW@refs/tags/rehearsal" "someone/fork/.github/workflows/release.yml@refs/heads/main" \
		"$WORKFLOW@refs/heads/a b"; do
		export GITHUB_WORKFLOW_REF=$ref
		sign sign
		expect_status 1
		has_line "✘ GITHUB_WORKFLOW_REF $(printf '%q' "$ref") is not $WORKFLOW on a branch"
		expect_eq "$(count_lines "$FAKE_DIR/order.log")" 0
	done
	expect_clean
}

@test "sign: a bad target, digest or missing input fails before any call" {
	export PUBLIC_REPO=$PROD
	sign sign
	expect_status 1
	has_line "✘ a practice run must not publish to the production repo $PROD"
	export PUBLIC_REPO=$SANDBOX DIGEST=sha256:ABC
	sign sign
	expect_status 1
	has_line "✘ DIGEST sha256:ABC is not sha256:<64 lowercase hex>"
	export DIGEST=sha256:3333333333333333333333333333333333333333333333333333333333333333
	unset ACTIONS_ID_TOKEN_REQUEST_TOKEN
	sign sign
	expect_status 1
	has_line "✘ ACTIONS_ID_TOKEN_REQUEST_TOKEN is not set"
	expect_eq "$(count_lines "$FAKE_DIR/order.log")" 0
	expect_clean
}

# --- verify ------------------------------------------------------------------------------------------------------

@test "verify: checks the signature with no credentials and no saved login" {
	no_credentials
	sign verify
	expect_status 0
	has_line "✔ $SANDBOX@$DIGEST is signed by $MAIN_IDENTITY (checked anonymously)"
	expect_eq "$(cat "$FAKE_DIR/order.log")" "cosign verify key= login=no"
	expect_clean
}

@test "verify: reads again when there is no signature yet, and fails after 4 reads" {
	no_credentials
	cosign_route verify 1,0
	sign verify
	expect_status 0
	has_line "  no signature from $MAIN_IDENTITY yet (attempt 1 of 4); reading again"
	expect_eq "$(count_lines "$FAKE_DIR/cosign.calls")" 2

	setup
	no_credentials
	cosign_route verify 1
	sign verify
	expect_status 1
	has_line "  no signature from $MAIN_IDENTITY yet (attempt 3 of 4); reading again"
	has_line "  made-up cosign verify error"
	has_line "✘ $SANDBOX@$DIGEST has no signature from $MAIN_IDENTITY (checked 4 times, anonymously)"
	expect_eq "$(count_lines "$FAKE_DIR/cosign.calls")" 4
	expect_clean
}

@test "verify: refuses to run with any AWS credential variable set" {
	local name
	for name in AWS_ACCESS_KEY_ID AWS_SESSION_TOKEN AWS_PROFILE AWS_DEFAULT_PROFILE AWS_ROLE_ARN \
		AWS_CONTAINER_CREDENTIALS_FULL_URI; do
		no_credentials
		export "$name=x"
		sign verify
		expect_status 1
		has_line "✘ $name is set; this check must run with no AWS credentials"
		unset "$name"
	done
	expect_eq "$(count_lines "$FAKE_DIR/order.log")" 0
}

@test "verify: refuses to run unless the instance metadata is turned off" {
	local value
	for value in unset false; do
		no_credentials
		if [[ "$value" == unset ]]; then
			unset AWS_EC2_METADATA_DISABLED
		else
			export AWS_EC2_METADATA_DISABLED=$value
		fi
		sign verify
		expect_status 1
		has_line "✘ AWS_EC2_METADATA_DISABLED must be true, so no credentials come from the runner's instance metadata"
	done
	expect_eq "$(count_lines "$FAKE_DIR/order.log")" 0
}

@test "verify: a real run checks for release.yml on main only" {
	no_credentials
	export PRACTICE=false PUBLIC_REPO=$PROD GITHUB_WORKFLOW_REF=$WORKFLOW@refs/heads/other
	sign verify
	expect_status 1
	has_line "✘ a real run must be $WORKFLOW on main, not $WORKFLOW@refs/heads/other"
	expect_eq "$(count_lines "$FAKE_DIR/order.log")" 0
}

# --- install-cosign ----------------------------------------------------------------------------------------------

@test "install-cosign: a download that doesn't match the pinned sha256 is refused and nothing is installed" {
	local arch url
	for arch in X64:$COSIGN_AMD64_URL ARM64:$COSIGN_ARM64_URL; do
		setup
		export RUNNER_ARCH=${arch%%:*}
		url=${arch#*:}
		printf 'not the cosign release' >"$FAKE_DIR/fixtures/tampered.download"
		route "$url" tampered
		sign install-cosign
		expect_status 1
		has_line "✘ the cosign v3.1.4 download hashes to $(digest_of "$FAKE_DIR/fixtures/tampered.download"), not the pinned $([[ ${arch%%:*} == X64 ]] && echo 424e2c97d0b45fd7a6b608a87f090f35633f4c23ece5f092d48bba11aaf4bbfa || echo ade83b7aac62e131cacfe96d958948b2150cc9efec46a570a2649b8e27dedad2)"
		expect_eq "$(cat "$FAKE_DIR/curl.calls")" "120 $url"
		expect_eq "$(cat "$GITHUB_PATH")" ""
		if [[ -e "$RUNNER_TEMP/bin/cosign" ]]; then
			echo "cosign was installed"
			return 1
		fi
		expect_clean
	done
}

@test "install-cosign: a failed download fails" {
	local reply
	for reply in neterror http404; do
		setup
		route "$COSIGN_AMD64_URL" "$reply"
		sign install-cosign
		expect_status 1
		has_line "✘ could not download $COSIGN_AMD64_URL (curl exit $([[ $reply == neterror ]] && echo 6 || echo 22))"
		expect_eq "$(cat "$GITHUB_PATH")" ""
		expect_clean
	done
}

@test "install-cosign: an unknown runner arch fails before any download" {
	export RUNNER_ARCH=ARM
	sign install-cosign
	expect_status 1
	has_line "✘ no pinned cosign for RUNNER_ARCH ARM (only X64 and ARM64)"
	expect_eq "$(count_lines "$FAKE_DIR/curl.calls")" 0
}

@test "install-cosign: a release that matches the pin is installed into RUNNER_TEMP/bin and put on the PATH" {
	local copy="$BATS_TEST_TMPDIR/pinned-scripts"
	printf '#!/bin/sh\necho fake cosign\n' >"$FAKE_DIR/fixtures/release.download"
	mkdir -p "$copy"
	cp "$SCRIPTS_DIR/sign-image.sh" "$SCRIPTS_DIR/registry-lib.sh" "$copy/"
	edit_file "$copy/sign-image.sh" \
		"s/^readonly COSIGN_SHA256_AMD64=.*/readonly COSIGN_SHA256_AMD64=$(digest_of "$FAKE_DIR/fixtures/release.download")/"
	SCRIPT="$copy/sign-image.sh"
	route "$COSIGN_AMD64_URL" release
	sign install-cosign
	expect_status 0
	has_line "✔ installed cosign v3.1.4 (linux-amd64, sha256 $(digest_of "$FAKE_DIR/fixtures/release.download")) into $RUNNER_TEMP/bin"
	expect_eq "$(cat "$GITHUB_PATH")" "$RUNNER_TEMP/bin"
	expect_eq "$("$RUNNER_TEMP/bin/cosign")" "fake cosign"
	expect_clean
}

# By hand only: LIVE=1 bats .github/scripts/tests
@test "live: install-cosign downloads the pinned release for both arches and installs it" {
	if [[ "${LIVE:-0}" != 1 ]]; then
		skip "set LIVE=1 to download the real cosign release"
	fi
	local arch
	for arch in X64 ARM64; do
		setup
		export PATH="${PATH#"$BATS_TEST_DIRNAME/fake-bin:"}" RUNNER_ARCH=$arch
		sign install-cosign
		expect_status 0
		if [[ "$output" != *"✔ installed cosign v3.1.4 "* ]]; then
			echo "no install line: $output"
			return 1
		fi
		if [[ ! -x "$RUNNER_TEMP/bin/cosign" ]]; then
			echo "cosign is not installed as an executable file"
			return 1
		fi
		expect_clean
	done
}

@test "usage: an unknown command prints the usage" {
	sign nope
	expect_status 2
	expect_eq "$output" "usage: $SCRIPT install-cosign | sign | verify"
}
