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
