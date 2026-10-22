#!/usr/bin/env bats
#
# Structure tests for the release workflow's YAML. actionlint can't check what these check (and can't parse
# release.yml's self-repository reusable call), so these line-based checks verify how jobs and steps are wired.
# They follow image-check.bats: awk pulls out one job or step block, and each test asserts exact lines in it. The
# parsers rely on this repo's layout: jobs at 2 spaces, job keys at 4, steps at "      - name:".
#
# One section per part of the release workflow, each headed "# --- <part> ---" with what it covers.

load test_helper

RELEASE="$REAL_REPO/.github/workflows/release.yml"
CHART_RELEASE="$REAL_REPO/.github/workflows/release-chart.yml"

setup() {
	common_setup
}

teardown() {
	common_teardown
}

# The job ids of a workflow, in order.
job_ids() {
	awk '
		/^jobs:$/ { inside = 1; next }
		inside && /^[^ #]/ { exit }
		inside && /^  [A-Za-z0-9_-]+:$/ { sub(/^  /, ""); sub(/:$/, ""); print }
	' "$1"
}

# job_block <file> <job id> : the job's lines, from its "  <id>:" line up to the next job.
job_block() {
	awk -v id="  $2:" '
		/^jobs:$/ { jobs = 1; next }
		jobs && $0 == id { inside = 1; print; next }
		inside && (/^  [A-Za-z0-9_-]+:$/ || /^[^ #]/) { exit }
		inside { print }
	' "$1"
}

# The job ids in a job block's needs:, one per line. Reads "needs: a" and "needs: [a, b]"; any other form gives
# nothing, so check_direct_needs then flags every outputs reference in that job.
needs_of() {
	awk '
		/^    needs:/ {
			value = $0
			sub(/^    needs:[ ]*/, "", value)
			gsub(/[][ ]/, "", value)
			n = split(value, parts, ",")
			for (i = 1; i <= n; i++) print parts[i]
			exit
		}
	'
}

# check_direct_needs <file> : every needs.<job>.outputs reference in a job names a job in that job's own needs:
# (GitHub only exposes the outputs of direct needs). Prints each violation; returns 1 if there is one.
check_direct_needs() {
	local file=$1 job block needs ref bad=0
	for job in $(job_ids "$file"); do
		block=$(job_block "$file" "$job")
		needs=$(printf '%s\n' "$block" | needs_of)
		for ref in $(printf '%s\n' "$block" | grep -oE 'needs\.[A-Za-z0-9_-]+\.outputs' | sed -E 's/^needs\.|\.outputs$//g' | sort -u); do
			if ! printf '%s\n' "$needs" | grep -qxF -- "$ref"; then
				echo "$job reads needs.$ref.outputs but its needs: is [$(printf '%s' "$needs" | tr '\n' ' ')]"
				bad=1
			fi
		done
	done
	return "$bad"
}

# step_block <job block> <step name> : the step's lines, from "      - name: <name>" to the next step.
step_block() {
	printf '%s\n' "$1" | awk -v name="      - name: $2" '
		$0 == name { inside = 1; print; next }
		inside && /^      - name:/ { exit }
		inside { print }
	'
}

# Line number of a step within a job block, or nothing.
step_line() { printf '%s\n' "$1" | grep -nxF "      - name: $2" | cut -d: -f1; }

# count_matching <text> <extended regex> : the number of lines of text matching it.
count_matching() { printf '%s\n' "$1" | grep -cE -- "$2" || true; }

# --- direct needs ---------------------------------------------------------------------------------------------------

@test "self-check: a job reading the outputs of a job it doesn't need directly is caught" {
	local file="$BATS_TEST_TMPDIR/bad.yml"
	cat >"$file" <<'YAML'
on: push
jobs:
  a:
    runs-on: x
  b:
    needs: a
    runs-on: x
  c:
    needs: [b]
    env:
      X: ${{ needs.b.outputs.x }}
      Y: ${{ needs.a.outputs.y }}
YAML
	run check_direct_needs "$file"
	expect_status 1
	expect_eq "$output" "c reads needs.a.outputs but its needs: is [b]"
}

@test "release.yml: every needs.<job>.outputs reference names a job in that job's own needs" {
	local refs
	run check_direct_needs "$RELEASE"
	expect_status 0
	expect_eq "$output" ""
	# Not vacuous: the file has jobs that read other jobs' outputs.
	refs=$(grep -cE 'needs\.[A-Za-z0-9_-]+\.outputs' "$RELEASE" || true)
	if ((refs < 10)); then
		echo "only $refs needs.*.outputs references found; is the parser reading the file?"
		return 1
	fi
	job_ids "$RELEASE" | grep -qxF publish-version-tags
}

@test "release-chart.yml: every needs.<job>.outputs reference names a job in that job's own needs" {
	run check_direct_needs "$CHART_RELEASE"
	expect_status 0
	expect_eq "$output" ""
	# Not vacuous: the parser finds the jobs that read extract-image-info's outputs.
	job_ids "$CHART_RELEASE" | grep -qxF check-image-public
	job_ids "$CHART_RELEASE" | grep -qxF integration-tests
}

# --- publish-version-tags --------------------------------------------------------------------------------------------

@test "publish-version-tags: needs build and stage, and keeps the repo guard" {
	local block
	block=$(job_block "$RELEASE" publish-version-tags)
	expect_eq "$(printf '%s\n' "$block" | needs_of | tr '\n' ' ')" "build stage "
	expect_eq "$(count_matching "$block" "^    # Keep this guard in any future \`if:\`\\.$")" 1
	expect_eq "$(count_matching "$block" "^    if: github\\.repository == 'aws/secrets-store-csi-driver-provider-aws'$")" 1
	expect_eq "$(count_matching "$block" '^    if:')" 1
}

@test "publish-version-tags: one release at a time, under the workflow's release-image group" {
	local file
	file=$(cat "$RELEASE")
	expect_eq "$(count_matching "$file" '^concurrency:$')" 1
	expect_eq "$(count_matching "$file" '^  group: release-image$')" 1
	expect_eq "$(count_matching "$file" '^  cancel-in-progress: false$')" 1
	# Without it, a new run would cancel a run that is still waiting in the group.
	expect_eq "$(count_matching "$file" '^  queue: max$')" 1
	# A job-level group would let that job run beside another release.
	expect_eq "$(count_matching "$file" '^ +concurrency:')" 0
}

@test "publish-version-tags: sandbox environment when practice, prod otherwise" {
	local block
	block=$(job_block "$RELEASE" publish-version-tags)
	expect_eq "$(count_matching "$block" "^    environment: \\$\\{\\{ inputs\\.practice && 'sandbox' \\|\\| 'prod' \\}\\}$")" 1
	expect_eq "$(count_matching "$block" '^    environment:')" 1
}

@test "publish-version-tags: least-privilege permissions, a fixed runner, a timeout and the publicRepo output" {
	local block permissions
	block=$(job_block "$RELEASE" publish-version-tags)
	permissions=$(printf '%s\n' "$block" | awk '/^    permissions:$/ { inside = 1; next } inside && /^    [^ ]/ { exit } inside')
	expect_eq "$permissions" "      contents: read
      id-token: write"
	expect_eq "$(count_matching "$block" '^    runs-on: ubuntu-24\.04$')" 1
	expect_eq "$(count_matching "$block" '^    timeout-minutes: 30$')" 1
	expect_eq "$(count_matching "$block" '^    outputs:$')" 1
	expect_eq "$(count_matching "$block" '^      publicRepo: \$\{\{ steps\.copy\.outputs\.publicRepo \}\}$')" 1
}

@test "publish-version-tags: the pre-check runs before the copy, and both after the credential checks" {
	local block tags accounts crane creds noenv precheck copy cleanup
	block=$(job_block "$RELEASE" publish-version-tags)
	tags=$(step_line "$block" "Work out the public tags")
	accounts=$(step_line "$block" "Check the role ARNs")
	crane=$(step_line "$block" "Install crane")
	creds=$(step_line "$block" "Get AWS credentials")
	noenv=$(step_line "$block" "Check no AWS keys reached the job environment")
	precheck=$(step_line "$block" "Check the version tags are free")
	copy=$(step_line "$block" "Copy the tested image to the version tags")
	cleanup=$(step_line "$block" "Remove any registry logins left behind")
	if ! ((tags < accounts && accounts < crane && crane < creds && creds < noenv && noenv < precheck &&
		precheck < copy && copy < cleanup)); then
		echo "order: tags $tags, accounts $accounts, crane $crane, creds $creds, no-env $noenv, precheck $precheck, copy $copy, cleanup $cleanup"
		return 1
	fi
	# crane is installed before any AWS credentials exist, so that step gets none.
	step_block "$block" "Install crane" | grep -qxF '        run: bash .github/scripts/publish-image.sh install-crane'
	expect_eq "$(count_matching "$(step_block "$block" "Install crane")" 'steps\.aws\.outputs|^        env:')" 0
	step_block "$block" "Check the version tags are free" |
		grep -qxF '        run: bash .github/scripts/publish-image.sh precheck-version-tags'
	step_block "$block" "Copy the tested image to the version tags" |
		grep -qxF '        run: bash .github/scripts/publish-image.sh copy-version-tags'
	# No other step writes to the public repo (comment lines aside).
	expect_eq "$(printf '%s\n' "$block" | grep -v '^ *#' |
		grep -cE 'copy-version-tags|crane (copy|tag|push|mutate|append|delete)|docker (image )?push|ecr-public (put-image|batch-delete-image)' || true)" 1
}

@test "publish-version-tags: the credentials step uses the publish role and keeps keys out of the job env" {
	local step
	step=$(step_block "$(job_block "$RELEASE" publish-version-tags)" "Get AWS credentials")
	expect_eq "$(count_matching "$step" '^          role-to-assume: \$\{\{ vars\.PUBLISH_ROLE_ARN \}\}$')" 1
	expect_eq "$(count_matching "$step" '^          aws-region: us-east-1$')" 1
	expect_eq "$(count_matching "$step" '^          allowed-account-ids: \$\{\{ steps\.accounts\.outputs\.publishAccountId \}\}$')" 1
	expect_eq "$(count_matching "$step" '^          output-credentials: true$')" 1
	expect_eq "$(count_matching "$step" '^          output-env-credentials: false$')" 1
}

@test "publish-version-tags: both publish steps take the digest from build and the keys from the credentials step" {
	local block name step
	block=$(job_block "$RELEASE" publish-version-tags)
	for name in "Check the version tags are free" "Copy the tested image to the version tags"; do
		step=$(step_block "$block" "$name")
		expect_eq "$(count_matching "$step" '^          DIGEST: \$\{\{ needs\.build\.outputs\.digest \}\}$')" 1
		expect_eq "$(count_matching "$step" '^          AWS_SECRET_ACCESS_KEY: \$\{\{ steps\.aws\.outputs\.aws-secret-access-key \}\}$')" 1
	done
	step=$(step_block "$block" "Copy the tested image to the version tags")
	expect_eq "$(count_matching "$step" '^          IMAGE_REPO: \$\{\{ needs\.build\.outputs\.imageRepo \}\}$')" 1
}

@test "publish-version-tags: a final always() step removes any leftover DOCKER_CONFIG" {
	local step
	step=$(step_block "$(job_block "$RELEASE" publish-version-tags)" "Remove any registry logins left behind")
	expect_eq "$(count_matching "$step" '^        if: always\(\)$')" 1
	expect_eq "$(count_matching "$step" '^        run: rm -rf "\$\{RUNNER_TEMP:\?\}"/dc\.\*$')" 1
}

@test "role-accounts runs only in jobs with the sandbox or prod environment" {
	local job block found=0
	for job in $(job_ids "$RELEASE"); do
		block=$(job_block "$RELEASE" "$job")
		if [[ "$block" == *"publish-image.sh role-accounts"* ]]; then
			found=$((found + 1))
			expect_eq "$(count_matching "$block" "^    environment: \\$\\{\\{ inputs\\.practice && 'sandbox' \\|\\| 'prod' \\}\\}$")" 1
		fi
	done
	if ((found == 0)); then
		echo "no job runs role-accounts"
		return 1
	fi
}

# --- anonymous verify jobs -------------------------------------------------------------------------------------------

# check_no_credential_path <file> <job id> : the job has no way to get AWS credentials. Outside comments: no
# id-token, no environment, no secrets reference, no uses: but harden-runner and checkout, and no AWS_* name in the
# workflow, job or step env: except "AWS_EC2_METADATA_DISABLED: 'true'". Prints each problem; returns 1 if any.
check_no_credential_path() {
	local file=$1 job=$2 block uses name bad=0
	block=$(job_block "$file" "$job" | grep -v '^ *#' || true)
	if [[ -z "$block" ]]; then
		echo "no job $job"
		return 1
	fi
	if [[ "$block" == *id-token* ]]; then
		echo "$job has id-token"
		bad=1
	fi
	if [[ "$(count_matching "$block" '^ +environment:')" != 0 ]]; then
		echo "$job has an environment"
		bad=1
	fi
	# The word secrets in any form (secrets.X, secrets['X'], toJSON(secrets)), but not inside a name like the repo's.
	if printf '%s\n' "$block" | grep -qE '(^|[^A-Za-z0-9_/-])secrets([^A-Za-z0-9_-]|$)'; then
		echo "$job reads secrets"
		bad=1
	fi
	for uses in $(printf '%s\n' "$block" | sed -nE 's/^ +(- )?uses: ([^ ]+).*/\2/p'); do
		case "$uses" in
		step-security/harden-runner@* | actions/checkout@*) ;;
		*)
			echo "$job uses $uses"
			bad=1
			;;
		esac
	done
	for name in $(printf '%s\n' "$block" | grep -oE 'AWS_[A-Z0-9_]+' | sort -u); do
		if [[ "$name" != AWS_EC2_METADATA_DISABLED ]]; then
			echo "$job names $name"
			bad=1
		fi
	done
	if [[ "$block" == *AWS_EC2_METADATA_DISABLED* &&
		"$(count_matching "$block" "^ +AWS_EC2_METADATA_DISABLED: 'true'$")" != "$(count_matching "$block" AWS_EC2_METADATA_DISABLED)" ]]; then
		echo "$job sets AWS_EC2_METADATA_DISABLED to something other than 'true'"
		bad=1
	fi
	if awk '/^jobs:$/ { exit } !/^ *#/' "$file" | grep -q 'AWS_'; then
		echo "the workflow names an AWS_ variable outside its jobs"
		bad=1
	fi
	return "$bad"
}

@test "verify-image and verify-alias-tags: have no way to get AWS credentials" {
	local job
	for job in verify-image verify-alias-tags; do
		run check_no_credential_path "$RELEASE" "$job"
		expect_status 0
		expect_eq "$output" ""
	done
}

@test "verify-image: needs build and publish-version-tags, reads only, and checks build's digest" {
	local block permissions step
	block=$(job_block "$RELEASE" verify-image)
	expect_eq "$(printf '%s\n' "$block" | needs_of | tr '\n' ' ')" "build publish-version-tags "
	expect_eq "$(count_matching "$block" "^    # Keep this guard in any future \`if:\`\\.$")" 1
	expect_eq "$(count_matching "$block" "^    if: github\\.repository == 'aws/secrets-store-csi-driver-provider-aws'$")" 1
	permissions=$(printf '%s\n' "$block" | awk '/^    permissions:$/ { inside = 1; next } inside && /^    [^ ]/ { exit } inside')
	expect_eq "$permissions" "      contents: read"
	expect_eq "$(count_matching "$block" '^    runs-on: ubuntu-24\.04$')" 1
	expect_eq "$(count_matching "$block" '^    timeout-minutes: 15$')" 1
	step_block "$block" "Checkout" | grep -qxF '          persist-credentials: false'
	step=$(step_block "$block" "Check the version tags anonymously")
	expect_eq "$(count_matching "$step" '^        run: bash \.github/scripts/verify-public-image\.sh version-tags$')" 1
	expect_eq "$(count_matching "$step" '^          DIGEST: \$\{\{ needs\.build\.outputs\.digest \}\}$')" 1
	expect_eq "$(count_matching "$step" '^          PUBLIC_REPO: \$\{\{ needs\.publish-version-tags\.outputs\.publicRepo \}\}$')" 1
	expect_eq "$(count_matching "$step" '^          VERSION_TAGS: \$\{\{ steps\.tags\.outputs\.versionTags \}\}$')" 1
	expect_eq "$(count_matching "$step" "^          AWS_EC2_METADATA_DISABLED: 'true'$")" 1
}

# --- public-image-integ ----------------------------------------------------------------------------------------------

@test "public-image-integ: tests the public repo, pinned by build's digest, with the secrets passed by name" {
	local block
	block=$(job_block "$RELEASE" public-image-integ)
	expect_eq "$(printf '%s\n' "$block" | needs_of | tr '\n' ' ')" "build publish-version-tags verify-image "
	expect_eq "$(count_matching "$block" "^    if: github\\.repository == 'aws/secrets-store-csi-driver-provider-aws'$")" 1
	expect_eq "$(count_matching "$block" '^    uses: \$/\.github/workflows/integ\.yml$')" 1
	expect_eq "$(count_matching "$block" '^      imageRepo: \$\{\{ needs\.publish-version-tags\.outputs\.publicRepo \}\}$')" 1
	expect_eq "$(count_matching "$block" '^      imageTagAmd64: \$\{\{ needs\.build\.outputs\.stageTag \}\}$')" 1
	expect_eq "$(count_matching "$block" '^      imageTagArm64: \$\{\{ needs\.build\.outputs\.stageTag \}\}$')" 1
	expect_eq "$(count_matching "$block" '^      imageDigest: \$\{\{ needs\.build\.outputs\.digest \}\}$')" 1
	expect_eq "$(count_matching "$block" '^      ROLE_ARN: \$\{\{ secrets\.ROLE_ARN \}\}$')" 1
	expect_eq "$(count_matching "$block" '^      POD_IDENTITY_ROLE_ARN: \$\{\{ secrets\.POD_IDENTITY_ROLE_ARN \}\}$')" 1
}

@test "public-image-integ: build's stageTag is the first version tag, in real and practice runs" {
	local practice stage first
	for practice in false true; do
		: >"$BATS_TEST_TMPDIR/out"
		GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" VERSION=3.1.5 PRACTICE=$practice STAGING_REGISTRY=111122223333.dkr.ecr.us-west-2.amazonaws.com \
			GITHUB_RUN_ID=7 GITHUB_RUN_ATTEMPT=1 GITHUB_SHA=0123456789abcdef0123456789abcdef01234567 \
			bash "$SCRIPTS_DIR/release-tags.sh" >/dev/null
		GITHUB_OUTPUT="$BATS_TEST_TMPDIR/out" VERSION=3.1.5 PRACTICE=$practice GITHUB_RUN_ID=7 \
			bash "$SCRIPTS_DIR/public-tags.sh" >/dev/null
		stage=$(sed -n 's/^stageTag=//p' "$BATS_TEST_TMPDIR/out")
		first=$(sed -n 's/^versionTags=//p' "$BATS_TEST_TMPDIR/out" | cut -d' ' -f1)
		expect_eq "$stage" "$first"
	done
	expect_eq "$stage" rehearsal-7
}

# --- publish-alias-tags ----------------------------------------------------------------------------------------------

@test "publish-alias-tags: needs, guard, environment, permissions and output" {
	local block permissions
	block=$(job_block "$RELEASE" publish-alias-tags)
	expect_eq "$(printf '%s\n' "$block" | needs_of | tr '\n' ' ')" "build publish-version-tags verify-image public-image-integ "
	expect_eq "$(count_matching "$block" "^    if: github\\.repository == 'aws/secrets-store-csi-driver-provider-aws'$")" 1
	expect_eq "$(count_matching "$block" "^    environment: \\$\\{\\{ inputs\\.practice && 'sandbox' \\|\\| 'prod' \\}\\}$")" 1
	permissions=$(printf '%s\n' "$block" | awk '/^    permissions:$/ { inside = 1; next } inside && /^    [^ ]/ { exit } inside')
	expect_eq "$permissions" "      contents: read
      id-token: write"
	expect_eq "$(count_matching "$block" '^      previousDigests: \$\{\{ steps\.copy\.outputs\.previousDigests \}\}$')" 1
}

@test "publish-alias-tags: checks the repo, then credentials, then freshness, then the alias write" {
	local block repo tags accounts crane creds noenv fresh copy cleanup
	block=$(job_block "$RELEASE" publish-alias-tags)
	repo=$(step_line "$block" "Check the public repo is the one the version tags went to")
	tags=$(step_line "$block" "Work out the public tags")
	accounts=$(step_line "$block" "Check the role ARNs")
	crane=$(step_line "$block" "Install crane")
	creds=$(step_line "$block" "Get AWS credentials")
	noenv=$(step_line "$block" "Check no AWS keys reached the job environment")
	fresh=$(step_line "$block" "Check no newer release is published")
	copy=$(step_line "$block" "Point the alias tags at the tested image")
	cleanup=$(step_line "$block" "Remove any registry logins left behind")
	if ! ((repo < tags && tags < accounts && accounts < crane && crane < creds && creds < noenv &&
		noenv < fresh && fresh < copy && copy < cleanup)); then
		echo "order: repo $repo, tags $tags, accounts $accounts, crane $crane, creds $creds, no-env $noenv, fresh $fresh, copy $copy, cleanup $cleanup"
		return 1
	fi
	# Nothing runs between the freshness check and the alias writes.
	expect_eq "$(printf '%s\n' "$block" | sed -n 's/^      - name: //p' | grep -A1 -xF "Check no newer release is published" | tail -n 1)" \
		"Point the alias tags at the tested image"
}

# --- verify-alias-tags -----------------------------------------------------------------------------------------------

@test "verify-alias-tags: needs the alias job, reads only, and checks build's digest against its digest list" {
	local block permissions step
	block=$(job_block "$RELEASE" verify-alias-tags)
	expect_eq "$(printf '%s\n' "$block" | needs_of | tr '\n' ' ')" "build publish-version-tags publish-alias-tags "
	expect_eq "$(count_matching "$block" "^    if: github\\.repository == 'aws/secrets-store-csi-driver-provider-aws'$")" 1
	permissions=$(printf '%s\n' "$block" | awk '/^    permissions:$/ { inside = 1; next } inside && /^    [^ ]/ { exit } inside')
	expect_eq "$permissions" "      contents: read"
	expect_eq "$(count_matching "$block" '^    timeout-minutes: 15$')" 1
	step=$(step_block "$block" "Check the alias tags anonymously")
	expect_eq "$(count_matching "$step" '^        run: bash \.github/scripts/verify-public-image\.sh alias-tags$')" 1
	expect_eq "$(count_matching "$step" '^          DIGEST: \$\{\{ needs\.build\.outputs\.digest \}\}$')" 1
	expect_eq "$(count_matching "$step" '^          ALIAS_TAGS: \$\{\{ steps\.tags\.outputs\.aliasTags \}\}$')" 1
	expect_eq "$(count_matching "$step" '^          PREVIOUS_DIGESTS: \$\{\{ needs\.publish-alias-tags\.outputs\.previousDigests \}\}$')" 1
}

# --- bump-manifest-pr ------------------------------------------------------------------------------------------------

@test "bump-manifest-pr: real runs only, no environment, and only the write permissions a pull request needs" {
	local block permissions
	block=$(job_block "$RELEASE" bump-manifest-pr)
	expect_eq "$(printf '%s\n' "$block" | needs_of | tr '\n' ' ')" "build publish-version-tags verify-alias-tags "
	expect_eq "$(count_matching "$block" "^    # Keep this guard in any future \`if:\`\\.$")" 1
	expect_eq "$(count_matching "$block" "^    if: github\\.repository == 'aws/secrets-store-csi-driver-provider-aws' && !inputs\\.practice$")" 1
	expect_eq "$(count_matching "$block" '^    if:')" 1
	expect_eq "$(count_matching "$block" '^ +environment:')" 0
	permissions=$(printf '%s\n' "$block" | awk '/^    permissions:$/ { inside = 1; next } inside && /^    [^ ]/ { exit } inside')
	expect_eq "$(printf '%s\n' "$permissions" | sed 's/ *#.*//')" "      contents: write
      pull-requests: write"
	expect_eq "$(count_matching "$block" '^    runs-on: ubuntu-24\.04$')" 1
	expect_eq "$(count_matching "$block" '^    timeout-minutes: 10$')" 1
}

@test "bump-manifest-pr: checks out main with full history, and only the open-pr step gets the token" {
	local block step
	block=$(job_block "$RELEASE" bump-manifest-pr)
	step=$(step_block "$block" "Checkout")
	expect_eq "$(count_matching "$step" '^          ref: main$')" 1
	expect_eq "$(count_matching "$step" '^          persist-credentials: false$')" 1
	expect_eq "$(count_matching "$step" '^          fetch-depth: 0$')" 1
	step=$(step_block "$block" "Point the install manifest at the new version")
	expect_eq "$(count_matching "$step" '^        run: bash \.github/scripts/bump-manifest\.sh edit$')" 1
	expect_eq "$(count_matching "$step" '^          DIGEST: \$\{\{ needs\.build\.outputs\.digest \}\}$')" 1
	step=$(step_block "$block" "Open the pull request")
	expect_eq "$(count_matching "$step" "^        if: steps\\.edit\\.outputs\\.changed == 'true'$")" 1
	expect_eq "$(count_matching "$step" '^        run: bash \.github/scripts/bump-manifest\.sh open-pr$')" 1
	expect_eq "$(count_matching "$step" '^          GH_TOKEN: \$\{\{ github\.token \}\}$')" 1
	expect_eq "$(count_matching "$block" 'GH_TOKEN|GITHUB_TOKEN|github\.token|secrets\.')" 1
	# Both steps read the repo publish-version-tags wrote to, and the practice flag check_target needs.
	expect_eq "$(count_matching "$block" '^          PUBLIC_REPO: \$\{\{ needs\.publish-version-tags\.outputs\.publicRepo \}\}$')" 2
	expect_eq "$(count_matching "$block" '^          PRACTICE: \$\{\{ inputs\.practice \}\}$')" 2
}

@test "nothing in the release workflow or its scripts merges a pull request" {
	local file hits
	for file in "$RELEASE" "$SCRIPTS_DIR"/*.sh; do
		hits=$(grep -v '^ *#' "$file" | grep -niE 'gh +pr +merge|gh +api .*merge|--auto|--admin|auto-?merge|merge_method|/merges|mergePullRequest' || true)
		if [[ -n "$hits" ]]; then
			printf '%s:\n%s\n' "$file" "$hits"
			return 1
		fi
	done
}

# --- release-chart.yml: check-image-public ---------------------------------------------------------------------------

@test "check-image-public: reads only, hardens the runner first, and checks extract-image-info's repo and tag" {
	local block permissions step
	block=$(job_block "$CHART_RELEASE" check-image-public)
	expect_eq "$(printf '%s\n' "$block" | needs_of | tr '\n' ' ')" "extract-image-info "
	permissions=$(printf '%s\n' "$block" | awk '/^    permissions:$/ { inside = 1; next } inside && /^    [^ ]/ { exit } inside')
	expect_eq "$permissions" "      contents: read"
	expect_eq "$(printf '%s\n' "$block" | sed -n 's/^      - name: //p' | tr '\n' '|')" \
		"Harden Runner|Checkout|Check the image is public|"
	step_block "$block" "Checkout" | grep -qxF '          persist-credentials: false'
	step=$(step_block "$block" "Check the image is public")
	expect_eq "$(count_matching "$step" '^        run: bash \.github/scripts/chart-image-public\.sh$')" 1
	expect_eq "$(count_matching "$step" '^          IMAGE_REPO: \$\{\{ needs\.extract-image-info\.outputs\.imageRepo \}\}$')" 1
	expect_eq "$(count_matching "$step" '^          IMAGE_TAG: \$\{\{ needs\.extract-image-info\.outputs\.imageTag \}\}$')" 1
	expect_eq "$(count_matching "$block" 'secrets|id-token|environment:')" 0
}

@test "check-image-public: the integration tests and the chart release both wait for it" {
	expect_eq "$(job_block "$CHART_RELEASE" release | needs_of | tr '\n' ' ')" \
		"unit-test integration-tests check-image-public "
	expect_eq "$(job_block "$CHART_RELEASE" integration-tests | needs_of | tr '\n' ' ')" \
		"extract-image-info check-image-public "
}

@test "release-scripts.yml runs these tests when a workflow or file they read changes" {
	local patterns file pattern found
	patterns=$(awk '/paths: &paths$/ { inside = 1; next } inside && !/^      - / { exit }
		inside { sub(/^      - /, ""); gsub(/'\''/, ""); print }' "$REAL_REPO/.github/workflows/release-scripts.yml")
	for file in .github/workflows/release.yml .github/workflows/release-chart.yml .github/workflows/integ.yml \
		.github/scripts/chart-image-public.sh deployment/aws-provider-installer.yaml "$CHART_DIR/values.yaml"; do
		found=0
		while IFS= read -r pattern; do
			# shellcheck disable=SC2053 # the pattern is a glob on purpose
			if [[ "$file" == $pattern ]]; then
				found=1
			fi
		done <<<"$patterns"
		if ((found == 0)); then
			echo "release-scripts.yml's paths miss $file"
			return 1
		fi
	done
}
