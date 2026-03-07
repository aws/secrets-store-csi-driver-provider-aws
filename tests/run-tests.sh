#!/bin/bash
#
# Test orchestrator for integration tests.
#
# Execution flow:
#   1. Parse arguments and validate configuration
#   2. Preflight checks (tools, credentials, stale resources, VPC capacity)
#   3. Deploy infrastructure for all targets in parallel
#   4. Run bats tests (single or parallel depending on target count)
#   5. Dump logs to stdout for CI visibility
#   6. Tear down infrastructure
#
# Usage: ./run-tests.sh [target] [--version <addon-version>]
#        ./run-tests.sh clean [target]
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Include vendored tools (bats, kubectl) and Apollo environment binaries in PATH.
# Harmless when these directories are empty or don't exist.
export PATH="${PATH}:${SCRIPT_DIR}/tools/bats/bin:${SCRIPT_DIR}/tools:${APOLLO_ENVIRONMENT_ROOT:-}/bin"

# ============================================================
# Configuration
# ============================================================

ADDON_VERSION="${ADDON_VERSION:-}"
INFRA_BACKEND="${INFRA_BACKEND:-auto}"
INSTALL_METHOD="${INSTALL_METHOD:-auto}"
RESOURCE_PREFIX="${RESOURCE_PREFIX:-}"
PIDS=()
LOG_DIR=""
DEPLOYED_TARGETS=""

# Timestamped log message to stdout
ts() { echo "[$(date '+%H:%M:%S')] $*"; }

# Resolve auto backends early so validation can check the actual method
if [[ "$INFRA_BACKEND" == "auto" ]]; then
	if command -v eksctl &>/dev/null; then INFRA_BACKEND=eksctl; else INFRA_BACKEND=cfn; fi
fi
if [[ "$INSTALL_METHOD" == "auto" ]]; then
	if [[ -n "${PRIVREPO:-}" ]]; then INSTALL_METHOD=helm; else INSTALL_METHOD=addon; fi
fi

# Shorthand for calling infra.sh from this script
infra() { bash "$SCRIPT_DIR/infra.sh" "$@"; }

# ============================================================
# Process cleanup
# ============================================================

# Kill background jobs and clean up infrastructure on exit.
on_exit() {
	local exit_code=$?
	# Kill any background jobs (parallel deploys or test runs) on exit
	local pids
	pids=$(jobs -p 2>/dev/null) || true
	if [[ -n "$pids" ]]; then
		kill $pids 2>/dev/null || true
		wait 2>/dev/null || true
	fi
	# Clean up deployed infrastructure if the script was interrupted
	if [[ -n "$DEPLOYED_TARGETS" ]]; then
		echo ""
		ts "Cleaning up infrastructure for: $DEPLOYED_TARGETS"
		for t in $DEPLOYED_TARGETS; do
			infra delete "$t" 2>/dev/null &
		done
		wait 2>/dev/null || true
	fi
	if [[ -n "${LOG_DIR:-}" && -d "${LOG_DIR:-}" ]]; then
		echo ""
		echo "Test logs: $LOG_DIR"
	fi
	exit $exit_code
}
trap 'on_exit' EXIT
trap 'exit 130' INT TERM

# ============================================================
# Region detection
# ============================================================

# Populate REGION and FAILOVERREGION by delegating to infra.sh.
detect_regions() {
	if [[ -n "${REGION:-}" && -n "${FAILOVERREGION:-}" ]]; then return; fi
	eval "$(infra print-regions)"
	export REGION FAILOVERREGION
}

# ============================================================
# Target resolution
# ============================================================
# Targets are arch-auth combinations: x64-irsa, x64-pod-identity, arm-irsa, arm-pod-identity.
# Shorthand names expand to multiple targets for convenience.

# Expand a target shorthand (e.g. "x64") into individual arch-auth combinations.
resolve_targets() {
	case "$1" in
		""|all)           echo "x64-irsa x64-pod-identity arm-irsa arm-pod-identity" ;;
		x64)              echo "x64-irsa x64-pod-identity" ;;
		arm)              echo "arm-irsa arm-pod-identity" ;;
		irsa)             echo "x64-irsa arm-irsa" ;;
		pod-identity)     echo "x64-pod-identity arm-pod-identity" ;;
		x64-irsa|x64-pod-identity|arm-irsa|arm-pod-identity) echo "$1" ;;
		*) echo "Error: Unknown target '$1'" >&2; exit 1 ;;
	esac
}

# ============================================================
# Preflight checks
# ============================================================

# Verify tools, credentials, stale resources, and VPC capacity before testing.
preflight() {
	local region="$1"; shift; local targets=("$@")
	ts "=== Preflight checks ==="

	# --- Required tools (varies by backend and install method) ---
	local missing=()
	for tool in aws kubectl bats envsubst; do
		if ! command -v "$tool" >/dev/null 2>&1; then missing+=("$tool"); fi
	done
	if [[ "$INFRA_BACKEND" == "eksctl" ]]; then
		if ! command -v eksctl >/dev/null 2>&1; then missing+=("eksctl"); fi
	fi
	if [[ "$INSTALL_METHOD" == "helm" ]]; then
		if ! command -v helm >/dev/null 2>&1; then missing+=("helm"); fi
	fi
	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "Error: Missing tools: ${missing[*]}"; exit 1
	fi

	# --- AWS credentials + optional account allowlist ---
	# ALLOWED_ACCOUNTS_FILE is an external file (one account ID per line, # comments allowed)
	# that restricts which AWS accounts can run these tests. Used in restricted environments
	# to prevent accidental runs against production accounts. Not set by default.
	local account
	account=$(aws sts get-caller-identity --query Account --output text 2>/dev/null) || {
		echo "Error: AWS credentials not configured"; exit 1
	}
	if [[ -n "${ALLOWED_ACCOUNTS_FILE:-}" && -f "${ALLOWED_ACCOUNTS_FILE:-}" ]]; then
		if ! grep -qxF "$account" <(sed 's/#.*//;s/ //g;/^$/d' "$ALLOWED_ACCOUNTS_FILE"); then
			echo "Error: Account $account not in allowlist ($ALLOWED_ACCOUNTS_FILE)"; exit 1
		fi
	fi

	# --- Clean up stale resources from previous runs ---
	infra cleanup-stale "${targets[@]}"

	# --- Detect concurrent test runs ---
	local other_stacks
	other_stacks=$(aws cloudformation list-stacks --region "$region" \
		--query "StackSummaries[?starts_with(StackName,'integ-cluster-') && StackStatus!='DELETE_COMPLETE' && StackStatus!='DELETE_IN_PROGRESS'].[StackName]" \
		--output text 2>/dev/null) || true
	if [[ -n "$other_stacks" ]]; then
		# Filter out stacks that belong to our target set (those are handled by cleanup-stale)
		local foreign=""
		for s in $other_stacks; do
			local is_ours=false
			for t in "${targets[@]}"; do
				if [[ "$s" == "integ-cluster-${t}" ]]; then is_ours=true; break; fi
			done
			if [[ "$is_ours" == "false" ]]; then foreign+=" $s"; fi
		done
		if [[ -n "$foreign" ]]; then
			echo "⚠ Warning: Found integ-cluster stacks from another run:$foreign"
			echo "  Another test run may be in progress. Use RESOURCE_PREFIX to avoid collisions."
		fi
	fi

	# --- Warn if failover region equals primary ---
	if [[ "$REGION" == "$FAILOVERREGION" ]]; then
		echo "⚠ Warning: FAILOVERREGION ($FAILOVERREGION) equals REGION — failover tests will not exercise cross-region behavior"
	fi

	# --- VPC capacity (each test target creates one VPC) ---
	local vpc_limit vpc_count available needed=${#targets[@]}
	vpc_limit=$(aws service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE \
		--query 'Quota.Value' --output text --region "$region" 2>/dev/null) || vpc_limit=5
	vpc_count=$(aws ec2 describe-vpcs --region "$region" --query 'length(Vpcs)' --output text)
	available=$((${vpc_limit%.*} - vpc_count))
	echo "VPC capacity: ${vpc_count}/${vpc_limit%.*} used, ${available} available, ${needed} needed"
	if [[ $available -lt $needed ]]; then
		echo "Error: Not enough VPC capacity"; exit 1
	fi

	ts "=== Preflight passed ==="
	echo ""
}

# ============================================================
# Infrastructure deployment (parallel)
# ============================================================

# Deploy infrastructure for all targets in parallel; exit on any failure.
# Each deploy writes to its own log file to avoid interleaved output.
deploy_all() {
	local deploy_pids=() failed=0
	for t in "$@"; do
		infra deploy "$t" >"${LOG_DIR}/deploy-${t}.log" 2>&1 &
		deploy_pids+=("$!:$t")
	done
	for entry in "${deploy_pids[@]}"; do
		if ! wait "${entry%%:*}"; then
			ts "✗ Deploy failed for ${entry#*:}"; failed=1
		else
			ts "✓ Deploy succeeded for ${entry#*:}"
		fi
	done
	if [[ $failed -eq 1 ]]; then
		echo "Error: Deployment failed. Deploy logs:"
		for t in "$@"; do
			local lf="${LOG_DIR}/deploy-${t}.log"
			if [[ -f "$lf" ]]; then echo "--- deploy: ${t} ---"; cat "$lf"; fi
		done
		echo "Cleaning up..."
		for t in "$@"; do infra delete "$t" 2>/dev/null || true; done
		exit 1
	fi
}

# ============================================================
# Test execution
# ============================================================

# Run bats for a single arch+auth target. All configuration is passed via
# environment variables so bats doesn't need to know about run-tests.sh internals.
run_test() {
	local arch=$1 auth_type=$2 label="${1}-${2}" parallel="${3:-false}"
	detect_regions
	local log_file="${LOG_DIR}/${label}.log"
	ts "Starting ${label} tests (log: ${log_file})..."

	local env_args=(
		ARCH="$arch" AUTH_TYPE="$auth_type" REGION="$REGION" FAILOVERREGION="$FAILOVERREGION"
		INFRA_BACKEND="$INFRA_BACKEND" INSTALL_METHOD="$INSTALL_METHOD"
		RESOURCE_PREFIX="$RESOURCE_PREFIX" ADDON_VERSION="$ADDON_VERSION"
		POD_IDENTITY_ROLE_ARN="${POD_IDENTITY_ROLE_ARN:-}"
		PRIVREPO="${PRIVREPO:-}" PRIVTAG="${PRIVTAG:-}" GHCR_TOKEN="${GHCR_TOKEN:-}"
		PROVIDER_YAML="${PROVIDER_YAML:-}" EKS_VERSION="${EKS_VERSION:-}"
	)

	if [[ "$parallel" == "true" ]]; then
		env "${env_args[@]}" bats ${BATS_FILTER:+--filter "$BATS_FILTER"} integration.bats >"$log_file" 2>&1 3>&1
		local rc=$?
		if [[ $rc -eq 0 ]]; then
			ts "✓ ${label} passed"
		else
			ts "✗ ${label} FAILED (see ${log_file})"
		fi
		return $rc
	else
		env "${env_args[@]}" bats ${BATS_FILTER:+--filter "$BATS_FILTER"} integration.bats 2>&1 | tee "$log_file"
		return "${PIPESTATUS[0]}"
	fi
}

# Run bats tests for multiple targets in parallel; return non-zero if any fail.
run_parallel() {
	local -A pid_target
	for target in "$@"; do
		run_test "${target%%-*}" "${target#*-}" true &
		pid_target[$!]="$target"
		PIDS+=($!)
	done
	FAILED_TARGETS=0
	for pid in "${PIDS[@]}"; do
		if ! wait "$pid"; then ((FAILED_TARGETS++)); fi
	done
	return $(( FAILED_TARGETS > 0 ? 1 : 0 ))
}

# ============================================================
# Argument parsing
# ============================================================

TEST_TARGET=""
CLEAN_TARGETS=""
SKIP_DEPLOY=false
SKIP_CLEANUP=false
BATS_FILTER=""
if [[ $# -gt 0 && "$1" == "clean" ]]; then
	TEST_TARGET="clean"; shift
	if [[ $# -gt 0 && "$1" != "--"* ]]; then CLEAN_TARGETS="$1"; shift; fi
elif [[ $# -gt 0 && "$1" != "--"* ]]; then
	TEST_TARGET="$1"; shift
fi
while [[ $# -gt 0 ]]; do
	case "$1" in
		--version) ADDON_VERSION="$2"; shift 2 ;;
		--skip-deploy) SKIP_DEPLOY=true; shift ;;
		--skip-cleanup) SKIP_CLEANUP=true; shift ;;
		--filter) BATS_FILTER="$2"; shift 2 ;;
		*) echo "Error: Unknown argument '$1'"; exit 1 ;;
	esac
done

# ============================================================
# Validation
# ============================================================

if [[ "$TEST_TARGET" != "clean" ]]; then
	if [[ "$(resolve_targets "${TEST_TARGET:-}")" == *"pod-identity"* && -z "${POD_IDENTITY_ROLE_ARN:-}" ]]; then
		echo "Error: POD_IDENTITY_ROLE_ARN required for pod-identity tests"; exit 1
	fi
	if [[ "$INSTALL_METHOD" == "helm" || "$INSTALL_METHOD" == "yaml" ]]; then
		if [[ -z "${PRIVREPO:-}" ]]; then
			echo "Error: PRIVREPO required for $INSTALL_METHOD install"; exit 1
		fi
		provider_yaml="${PROVIDER_YAML:-../deployment/private-installer.yaml}"
		if [[ ! -f "$provider_yaml" ]]; then
			echo "Error: PROVIDER_YAML not found at $provider_yaml"; exit 1
		fi
		# Validate that the image exists in ECR (only for ECR repos, not ghcr.io etc.)
		if [[ "$PRIVREPO" == *".dkr.ecr."*".amazonaws.com/"* ]]; then
			ecr_region=$(echo "$PRIVREPO" | sed 's/.*\.dkr\.ecr\.\(.*\)\.amazonaws\.com.*/\1/')
			ecr_repo=$(echo "$PRIVREPO" | sed 's/.*\.amazonaws\.com\///')
			ecr_tag="${PRIVTAG:-latest}"
			echo "Validating ECR image: ${PRIVREPO}:${ecr_tag}..."
			if ! aws ecr describe-images --repository-name "$ecr_repo" --image-ids "imageTag=$ecr_tag" \
				--region "$ecr_region" --query 'imageDetails[0].imageDigest' --output text >/dev/null 2>&1; then
				echo "Error: Image not found in ECR: ${PRIVREPO}:${ecr_tag}"; exit 1
			fi
			echo "✓ ECR image validated"
		fi
	fi
fi

# ============================================================
# Main execution
# ============================================================

cd "$SCRIPT_DIR"

# --- Clean mode: tear down and exit ---
# Detects how each cluster was created (cfn vs eksctl) by checking for the
# presence of eksctl-managed CFN stacks, rather than relying on INFRA_BACKEND.
if [[ "$TEST_TARGET" == "clean" ]]; then
	detect_regions
	local_targets=$(resolve_targets "${CLEAN_TARGETS:-all}")
	clean_dir=$(mktemp -d)
	ts "=== Cleaning up: $local_targets ==="
	for t in $local_targets; do
		(
			cluster="integ-cluster-${t}"
			# Check if this cluster was created by eksctl (eksctl-prefixed CFN stacks exist)
			eksctl_stack=$(aws cloudformation describe-stacks --stack-name "eksctl-${cluster}-cluster" \
				--region "$REGION" --query 'Stacks[0].StackStatus' --output text 2>/dev/null) || eksctl_stack=""
			if [[ -n "$eksctl_stack" ]]; then
				INFRA_BACKEND=eksctl
			else
				INFRA_BACKEND=cfn
			fi
			export INFRA_BACKEND
			bash "$SCRIPT_DIR/infra.sh" delete "$t"
		) >"${clean_dir}/${t}.log" 2>&1 &
	done
	wait
	for t in $local_targets; do
		echo ""
		echo "--- clean: ${t} ---"
		cat "${clean_dir}/${t}.log"
	done
	rm -rf "$clean_dir"
	echo ""
	ts "=== Cleanup complete ==="
	exit 0
fi

# --- Normal mode: preflight → deploy → test → results → cleanup ---
detect_regions
targets=$(resolve_targets "${TEST_TARGET:-all}")

echo "=== Test Configuration ==="
echo "  Region: $REGION | Failover: $FAILOVERREGION"
echo "  Targets: $targets"
echo "  Backend: $INFRA_BACKEND | Install: $INSTALL_METHOD | Prefix: ${RESOURCE_PREFIX:-(none)}"
if [[ "$INSTALL_METHOD" == "helm" || "$INSTALL_METHOD" == "yaml" ]]; then
	echo "  Provider image: ${PRIVREPO:-}${PRIVTAG:+:${PRIVTAG}}"
	echo "  Provider YAML: ${PROVIDER_YAML:-../deployment/private-installer.yaml}"
	driver_version=$(helm search repo secrets-store-csi-driver/secrets-store-csi-driver --output json 2>/dev/null \
		| grep -o '"version":"[^"]*"' | head -1 | cut -d'"' -f4) || true
	if [[ -n "${driver_version:-}" ]]; then
		echo "  CSI driver version: $driver_version (helm)"
	fi
fi
if [[ "$INSTALL_METHOD" == "addon" && -n "${ADDON_VERSION:-}" ]]; then
	echo "  Addon version: $ADDON_VERSION"
fi
echo ""

# shellcheck disable=SC2086
preflight "$REGION" $targets

LOG_DIR="logs/$(date +'%Y-%m-%d_%H-%M-%S')"; mkdir -p "$LOG_DIR"

if [[ "$SKIP_DEPLOY" == "true" ]]; then
	ts "Skipping deploy (--skip-deploy)"
else
	# shellcheck disable=SC2086
	deploy_all $targets
fi
DEPLOYED_TARGETS="$targets"

target_count=$(echo "$targets" | wc -w | tr -d ' ')

# Run tests. The || rc=$? prevents set -e from exiting before cleanup runs.
rc=0
FAILED_TARGETS=0
if [[ $target_count -eq 1 ]]; then
	run_test "${targets%%-*}" "${targets#*-}" || { rc=$?; FAILED_TARGETS=1; }
else
	# shellcheck disable=SC2086
	run_parallel $targets || rc=$?
fi

# Dump full logs to stdout so CI systems capture them in build output
echo ""
echo "=== Deploy Logs ==="
for f in "$LOG_DIR"/deploy-*.log; do
	if [[ -f "$f" ]]; then
		echo ""
		echo "--- $(basename "$f") ---"
		cat "$f"
	fi
done

echo ""
echo "=== Test Logs ==="
for t in $targets; do
	f="$LOG_DIR/${t}.log"
	if [[ -f "$f" ]]; then
		echo ""
		echo "--- $(basename "$f") ---"
		cat "$f"
	fi
done

echo ""
if [[ "$SKIP_CLEANUP" == "true" ]]; then
	ts "Skipping cleanup (--skip-cleanup)"
	DEPLOYED_TARGETS=""
else
	echo "=== Cleanup ==="
	cleanup_pids=()
	for t in $targets; do
		infra delete "$t" >"${LOG_DIR}/cleanup-${t}.log" 2>&1 &
		cleanup_pids+=("$!:$t")
	done
	for entry in "${cleanup_pids[@]}"; do
		if ! wait "${entry%%:*}"; then
			ts "✗ Cleanup failed for ${entry#*:}"
		else
			ts "✓ Cleanup succeeded for ${entry#*:}"
		fi
	done
	DEPLOYED_TARGETS=""
	for t in $targets; do
		if [[ -f "${LOG_DIR}/cleanup-${t}.log" ]]; then
			echo "--- cleanup: ${t} ---"
			cat "${LOG_DIR}/cleanup-${t}.log"
		fi
	done
fi

# Final summary
echo ""
if [[ $rc -eq 0 ]]; then
	ts "=== ${target_count} of ${target_count} targets passed ==="
else
	passed=$(( target_count - FAILED_TARGETS ))
	ts "=== ${passed} of ${target_count} targets passed ==="
fi
exit $rc
