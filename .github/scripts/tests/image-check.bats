#!/usr/bin/env bats
#
# Runs the pod image check from tests/integration.bats.template (the lines between the
# "# BEGIN image-check" and "# END image-check" markers) against a stub kubectl.
#
# Each case runs as its own bats process. Inside `run`, bats turns errexit off, so a failed assert there would not
# stop anything; and `log` writes to fd 3, which `run` doesn't capture. In a separate bats process the lines run in
# a @test body, exactly like the real integ run: the first failed assert stops the test, and the fd-3 log lines
# come out on that process's stdout, which the outer `run` does capture.

load test_helper

TEMPLATE="$REAL_REPO/tests/integration.bats.template"
D=sha256:1111111111111111111111111111111111111111111111111111111111111111
D2=sha256:2222222222222222222222222222222222222222222222222222222222222222
R=123456789012.dkr.ecr.us-west-2.amazonaws.com/ascp

# Copies the marked lines out of the template, with the generator's {{KUBECONFIG_VAR}} substitution, into
# $BATS_FILE_TMPDIR/image-check.lines (variables set here don't reach the tests; files do).
setup_file() {
	local line state=0 begins=0 ends=0 count=0 out="$BATS_FILE_TMPDIR/image-check.lines"
	local begin_re='^[[:space:]]*# BEGIN image-check$' end_re='^[[:space:]]*# END image-check$'
	local placeholder='{{KUBECONFIG_VAR}}' replacement='KUBECONFIG_TEST'
	: >"$out"
	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" =~ $begin_re ]]; then
			begins=$((begins + 1))
			state=1
			continue
		fi
		if [[ "$line" =~ $end_re ]]; then
			ends=$((ends + 1))
			if ((state != 1)); then
				echo "END marker before BEGIN in $TEMPLATE"
				return 1
			fi
			state=2
			continue
		fi
		if ((state == 1)); then
			printf '%s\n' "${line//"$placeholder"/$replacement}" >>"$out"
			count=$((count + 1))
		fi
	done <"$TEMPLATE"
	if ((begins != 1 || ends != 1 || state != 2)); then
		echo "need exactly one BEGIN and one END image-check marker, in that order (found $begins and $ends)"
		return 1
	fi
	if ((count == 0)) || ! grep -q '[^[:space:]]' "$out"; then
		echo "the image-check block is empty"
		return 1
	fi
	if grep -F '{{' "$out"; then
		echo "the image-check block has a placeholder the test doesn't fill in (above)"
		return 1
	fi

	mkdir -p "$BATS_FILE_TMPDIR/stub-bin"
	cat >"$BATS_FILE_TMPDIR/stub-bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# Stub kubectl: answers only the 2 exact queries the image check makes.
echo "$*" >>"$STUB_DIR/kubectl.calls"
if [[ $# -ne 7 || "$1" != "--kubeconfig=$KUBECONFIG_TEST" || "$2" != --namespace || "$3" != "$NAMESPACE" ||
	"$4" != get || "$5" != "pod/$PROVIDER_POD" || "$6" != -o ]]; then
	echo "kubectl: unexpected call: $*" >>"$STUB_DIR/violations"
	exit 99
fi
case "$7" in
'jsonpath={.spec.containers[0].image}')
	if [[ "${STUB_FAIL:-0}" == 1 ]]; then
		echo "Error from server (NotFound): pods not found" >&2
		exit 1
	fi
	if [[ "${STUB_WARN:-0}" == 1 ]]; then
		echo "Warning: a made-up kubectl warning" >&2
	fi
	printf '%s' "$STUB_IMAGE"
	;;
'jsonpath={.status.containerStatuses[0].imageID}') printf '%s' "$STUB_IMAGE_ID" ;;
*)
	echo "kubectl: unexpected query: $7" >>"$STUB_DIR/violations"
	exit 99
	;;
esac
STUB
	chmod +x "$BATS_FILE_TMPDIR/stub-bin/kubectl"
}

setup() {
	STUB_DIR="$BATS_TEST_TMPDIR/stub"
	mkdir -p "$STUB_DIR"
	: >"$STUB_DIR/kubectl.calls"
	: >"$STUB_DIR/violations"
}

teardown() {
	if [[ -s "$STUB_DIR/violations" ]]; then
		echo "stub violations:"
		cat "$STUB_DIR/violations"
		return 1
	fi
}

# Writes an inner .bats file whose @test body is the given file's lines, then runs it in a separate bats process
# with a clean environment.
# Usage: run_inner <body file> [NAME=value ...]
run_inner() {
	local body=$1 inner="$BATS_TEST_TMPDIR/inner.bats"
	shift
	{
		echo "load '$REAL_REPO/tests/helpers'"
		echo 'log() { echo "$1" >&3; }'
		echo '@test "image check" {'
		cat "$body"
		echo '}'
	} >"$inner"
	run env -i \
		HOME="$HOME" PATH="$BATS_FILE_TMPDIR/stub-bin:$PATH" \
		STUB_DIR="$STUB_DIR" NAMESPACE=kube-system PROVIDER_POD=provider-aws-abcde \
		KUBECONFIG_TEST="$BATS_TEST_TMPDIR/kubeconfig" STUB_IMAGE_ID="$R@$D" \
		"$@" \
		"$BATS_ROOT/bin/bats" "$inner"
}

# Runs the template's image-check lines with the given settings.
# Usage: check_image <pod image> [NAME=value ...]   (PRIVREPO defaults to $R)
check_image() {
	local image=$1
	shift
	run_inner "$BATS_FILE_TMPDIR/image-check.lines" PRIVREPO="$R" STUB_IMAGE="$image" "$@"
}

kubectl_calls() { count_lines "$STUB_DIR/kubectl.calls"; }

passed() {
	if [[ "$status" != 0 ]]; then
		printf 'expected the image check to pass, status %s\noutput:\n%s\n' "$status" "$output"
		return 1
	fi
}

failed() {
	if [[ "$status" == 0 ]]; then
		printf 'expected the image check to fail\noutput:\n%s\n' "$output"
		return 1
	fi
}

has_text() {
	if [[ "$output" != *"$1"* ]]; then
		printf 'missing text: %s\noutput:\n%s\n' "$1" "$output"
		return 1
	fi
}

# --- the harness itself ------------------------------------------------------------------------------------------

@test "self-check: a failure in the inner test is seen, and stops it" {
	printf '%s\n' 'log "hello"' 'false' 'log "after"' >"$BATS_TEST_TMPDIR/selfcheck.lines"
	run_inner "$BATS_TEST_TMPDIR/selfcheck.lines"
	failed
	has_text "hello"
	lacks_text "after"
}

@test "self-check: a passing inner test passes and its log is captured" {
	printf '%s\n' 'log "hello"' 'true' >"$BATS_TEST_TMPDIR/selfcheck.lines"
	run_inner "$BATS_TEST_TMPDIR/selfcheck.lines"
	passed
	has_text "hello"
}

@test "the extracted lines query the pod with the substituted kubeconfig" {
	grep -qF -- '--kubeconfig=$KUBECONFIG_TEST --namespace $NAMESPACE get pod/$PROVIDER_POD' "$BATS_FILE_TMPDIR/image-check.lines"
}

# --- cases -------------------------------------------------------------------------------------------------------

@test "digest given and pinned: passes and logs the digest check" {
	check_image "$R:3.1.5-testing@$D" EXPECT_DIGEST="$D" PRIVTAG="3.1.5-testing@$D"
	passed
	has_text "provider image: $R:3.1.5-testing@$D"
	has_text "✔ digest check passed ($D)"
	has_text "provider imageID (informational): $R@$D"
	expect_eq "$(kubectl_calls)" 2
}

@test "digest lost from PRIVTAG: fails at the digest check" {
	check_image "$R:3.1.5-testing" EXPECT_DIGEST="$D" PRIVTAG="3.1.5-testing"
	failed
	has_text "expected: @$D\$"
	has_text "actual: $R:3.1.5-testing"
	lacks_text "✔ digest check passed"
	expect_eq "$(kubectl_calls)" 1
}

@test "digest given, PRIVTAG empty (chart's default tag, no digest): fails at the digest check" {
	check_image "$R:3.1.4" EXPECT_DIGEST="$D" PRIVTAG=""
	failed
	has_text "expected: @$D\$"
	has_text "actual: $R:3.1.4"
	lacks_text "✔ digest check passed"
	expect_eq "$(kubectl_calls)" 1
}

@test "a different digest end to end: fails at the digest check" {
	check_image "$R:3.1.5-testing@$D2" EXPECT_DIGEST="$D" PRIVTAG="3.1.5-testing@$D2"
	failed
	has_text "expected: @$D\$"
	has_text "actual: $R:3.1.5-testing@$D2"
	lacks_text "✔ digest check passed"
	expect_eq "$(kubectl_calls)" 1
}

@test "right digest, wrong repo: fails at the exact-image check" {
	check_image "other/repo:3.1.5-testing@$D" EXPECT_DIGEST="$D" PRIVTAG="3.1.5-testing@$D"
	failed
	has_text "✔ digest check passed ($D)"
	has_text "expected: $R:3.1.5-testing@$D"
	has_text "actual: other/repo:3.1.5-testing@$D"
	expect_eq "$(kubectl_calls)" 1
}

@test "no digest, PRIVTAG matches: passes without a digest check" {
	check_image "$R:3.1.4" EXPECT_DIGEST="" PRIVTAG="3.1.4"
	passed
	has_text "provider image: $R:3.1.4"
	lacks_text "✔ digest check passed"
	expect_eq "$(kubectl_calls)" 2
}

@test "no digest, PRIVTAG differs: fails at the exact-image check" {
	check_image "$R:3.1.5" EXPECT_DIGEST="" PRIVTAG="3.1.4"
	failed
	has_text "expected: $R:3.1.4"
	has_text "actual: $R:3.1.5"
	expect_eq "$(kubectl_calls)" 1
}

@test "no digest, no PRIVTAG: passes and only logs" {
	check_image "public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws:3.1.4" EXPECT_DIGEST="" PRIVTAG=""
	passed
	has_text "provider image: public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws:3.1.4"
	lacks_text "✔ digest check passed"
	expect_eq "$(kubectl_calls)" 2
}

@test "a kubectl warning on stderr doesn't end up in the image: passes" {
	check_image "$R:3.1.5-testing@$D" EXPECT_DIGEST="$D" PRIVTAG="3.1.5-testing@$D" STUB_WARN=1
	passed
	has_text "provider image: $R:3.1.5-testing@$D"
	lacks_text "made-up kubectl warning"
}

@test "kubectl fails on the image query: fails at assert_success" {
	check_image "" EXPECT_DIGEST="$D" PRIVTAG="3.1.5-testing@$D" STUB_FAIL=1
	failed
	has_text "kubectl stderr: Error from server (NotFound): pods not found"
	has_text "expected: 0"
	lacks_text "✔ digest check passed"
	expect_eq "$(kubectl_calls)" 1
}

# --- integ.yml wiring --------------------------------------------------------------------------------------------

INTEG="$REAL_REPO/.github/workflows/integ.yml"

# Prints the lines of one step, from its "- name:" line up to the next step.
step_block() {
	awk -v name="      - name: $1" '
		$0 == name { inside = 1; print; next }
		inside && /^      - name:/ { exit }
		inside { print }
	' "$INTEG"
}

@test "integ.yml passes the digest to the tests and no longer overrides PRIVTAG" {
	local block
	block=$(step_block "Run integ tests")
	expect_eq "$(printf '%s\n' "$block" | grep -cE '^          EXPECT_DIGEST: \$\{\{ inputs\.imageDigest \}\}$' || true)" 1
	expect_eq "$(printf '%s\n' "$block" | grep -cE '^[[:space:]]*PRIVTAG:' || true)" 0
}

@test "integ.yml declares imageDigest inside the shared inputs" {
	local block
	block=$(awk '
		/^    inputs: &inputs$/ { inside = 1; next }
		inside && /[^ ]/ && match($0, /^ */) && RLENGTH <= 4 { exit } # back at 4 spaces or less: block ended
		inside { print }
	' "$INTEG")
	expect_eq "$(printf '%s\n' "$block" | grep -cE '^      imageRepo:$' || true)" 1
	expect_eq "$(printf '%s\n' "$block" | grep -cE '^      imageDigest:$' || true)" 1
}

@test "integ.yml resolves the image after Checkout and before AWS credentials" {
	local checkout resolve credentials
	checkout=$(grep -nE '^      - name: Checkout$' "$INTEG" | cut -d: -f1)
	resolve=$(grep -nE '^      - name: Resolve image$' "$INTEG" | cut -d: -f1)
	credentials=$(grep -nE '^      - name: Configure AWS credentials$' "$INTEG" | cut -d: -f1)
	expect_eq "$(printf '%s\n' "$checkout" "$resolve" "$credentials" | wc -l | tr -d ' ')" 3
	if ! ((checkout < resolve && resolve < credentials)); then
		echo "order is Checkout:$checkout, Resolve image:$resolve, Configure AWS credentials:$credentials"
		return 1
	fi
	step_block "Resolve image" | grep -qxF '        run: bash .github/scripts/resolve-integ-image.sh'
}
