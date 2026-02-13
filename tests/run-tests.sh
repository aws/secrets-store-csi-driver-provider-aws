#!/bin/bash
set -euo pipefail

# --- Configuration ---

USE_ADDON=false
ADDON_VERSION=""
PIDS=()
LOG_DIR=""

# Activate venv if boto3 isn't already available
if ! python3 -c "import boto3" 2>/dev/null; then
	if [[ -f .venv/bin/activate ]]; then
		source .venv/bin/activate
	else
		echo "Error: boto3 not found. Run ./setup.sh or activate the venv manually."
		exit 1
	fi
fi

# --- Cleanup on exit/interrupt ---

on_exit() {
	local exit_code=$?
	if [[ ${#PIDS[@]} -gt 0 ]]; then
		echo "Stopping background processes..."
		for pid in "${PIDS[@]}"; do
			kill "$pid" 2>/dev/null && wait "$pid" 2>/dev/null || true
		done
	fi
	if [[ -n "$LOG_DIR" ]] && [[ -d "$LOG_DIR" ]]; then
		echo ""
		echo "Test logs: $LOG_DIR"
	fi
	[[ -d .venv ]] && deactivate 2>/dev/null || true
	exit $exit_code
}
trap on_exit EXIT INT TERM

# --- Region detection ---

detect_regions() {
	if [[ -n "${REGION:-}" ]] && [[ -n "${FAILOVERREGION:-}" ]]; then
		return
	fi
	eval "$(python3 test-manager.py print-regions)"
}

# --- Target resolution ---

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

target_needs_pod_identity() {
	[[ "$(resolve_targets "$1")" == *"pod-identity"* ]]
}

# --- Preflight checks ---

check_tools() {
	local missing=()
	for tool in aws eksctl kubectl bats; do
		command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
	done
	if [[ "$USE_ADDON" != "true" ]]; then
		command -v helm >/dev/null 2>&1 || missing+=("helm")
		command -v envsubst >/dev/null 2>&1 || missing+=("envsubst")
	fi
	if [[ ${#missing[@]} -gt 0 ]]; then
		echo "Error: Missing required tools: ${missing[*]}"
		exit 1
	fi
}

check_aws_credentials() {
	if ! aws sts get-caller-identity >/dev/null 2>&1; then
		echo "Error: AWS credentials not configured or expired"
		exit 1
	fi
}

# Clean up stale EKS clusters and orphaned CFN stacks for the given targets.
# Waits for in-progress operations and handles termination protection.
cleanup_stale_resources() {
	local region="$1"
	shift
	for target in "$@"; do
		local name="integ-cluster-${target}"

		# EKS cluster
		local status
		status=$(aws eks describe-cluster --name "$name" --region "$region" \
			--query 'cluster.status' --output text 2>/dev/null) || status=""
		if [[ "$status" == "DELETING" ]]; then
			echo "⏳ Cluster $name is deleting, waiting..."
			aws eks wait cluster-deleted --name "$name" --region "$region" 2>/dev/null || true
		elif [[ -n "$status" ]]; then
			echo "⚠ Cluster $name exists (status: $status), deleting..."
			eksctl delete cluster --name "$name" --parallel 25 || true
			aws eks wait cluster-deleted --name "$name" --region "$region" 2>/dev/null || true
		fi

		# Orphaned CFN stacks (eksctl creates eksctl-<name>-cluster and eksctl-<name>-nodegroup-*)
		local stack_prefix="eksctl-${name}"
		local stacks
		stacks=$(aws cloudformation list-stacks --region "$region" \
			--query "StackSummaries[?starts_with(StackName,'${stack_prefix}') && StackStatus!='DELETE_COMPLETE'].[StackName,StackStatus]" \
			--output text 2>/dev/null) || stacks=""

		while IFS=$'\t' read -r stack_name stack_status; do
			[[ -z "$stack_name" ]] && continue

			if [[ "$stack_status" == *"IN_PROGRESS"* ]]; then
				echo "⏳ Stack $stack_name ($stack_status), waiting..."
				aws cloudformation wait stack-"${stack_status%%_*}"-complete \
					--stack-name "$stack_name" --region "$region" 2>/dev/null || true
				# Re-check — it may have completed or rolled back
				stack_status=$(aws cloudformation describe-stacks --stack-name "$stack_name" --region "$region" \
					--query 'Stacks[0].StackStatus' --output text 2>/dev/null) || continue
			fi

			if [[ "$stack_status" != "DELETE_COMPLETE" && "$stack_status" != *"IN_PROGRESS"* ]]; then
				echo "⚠ Cleaning up stack $stack_name ($stack_status)..."
				aws cloudformation update-termination-protection --no-enable-termination-protection \
					--stack-name "$stack_name" --region "$region" 2>/dev/null || true
				aws cloudformation delete-stack --stack-name "$stack_name" --region "$region" 2>/dev/null || true
				aws cloudformation wait stack-delete-complete --stack-name "$stack_name" --region "$region" 2>/dev/null || true
			fi
		done <<< "$stacks"
	done
}

check_vpc_capacity() {
	local region="$1"
	local needed="$2"

	local vpc_limit
	vpc_limit=$(aws service-quotas get-service-quota --service-code vpc --quota-code L-F678F1CE \
		--query 'Quota.Value' --output text --region "$region" 2>/dev/null) || vpc_limit=5
	# service-quotas returns a float like "5.0"
	vpc_limit=${vpc_limit%.*}

	local vpc_count
	vpc_count=$(aws ec2 describe-vpcs --region "$region" --query 'length(Vpcs)' --output text)

	local available=$((vpc_limit - vpc_count))
	echo "VPC capacity: ${vpc_count}/${vpc_limit} used, ${available} available, ${needed} needed"

	if [[ $available -lt $needed ]]; then
		echo "Error: Not enough VPC capacity. Need $needed free VPCs but only $available available (limit: $vpc_limit)."
		echo "  Run './run-tests.sh clean' to remove stale test clusters, or request a VPC limit increase."
		exit 1
	fi
}

preflight() {
	local region="$1"
	shift
	local targets=("$@")
	local target_count=${#targets[@]}

	echo "=== Preflight checks ==="

	echo "Checking tools..."
	check_tools

	echo "Checking AWS credentials..."
	check_aws_credentials

	echo "Cleaning up stale resources..."
	cleanup_stale_resources "$region" "${targets[@]}"

	echo "Checking VPC capacity..."
	check_vpc_capacity "$region" "$target_count"

	echo "=== Preflight passed ==="
	echo ""
}

# --- Test execution ---

run_test() {
	local arch=$1 auth_type=$2
	local label="${arch}-${auth_type}"
	local parallel="${3:-false}"
	detect_regions

	local log_file="${LOG_DIR}/${label}.log"
	echo "Starting ${label} tests (log: ${log_file})..."

	if [[ "$parallel" == "true" ]]; then
		ARCH="$arch" AUTH_TYPE="$auth_type" \
			REGION="$REGION" FAILOVERREGION="$FAILOVERREGION" \
			USE_ADDON="$USE_ADDON" ADDON_VERSION="$ADDON_VERSION" \
			POD_IDENTITY_ROLE_ARN="${POD_IDENTITY_ROLE_ARN:-}" \
			PRIVREPO="${PRIVREPO:-}" PRIVTAG="${PRIVTAG:-}" \
			bats integration.bats >"$log_file" 2>&1
		local rc=$?
		if [[ $rc -eq 0 ]]; then
			echo "✓ ${label} passed"
		else
			echo "✗ ${label} FAILED (see ${log_file})"
		fi
		return $rc
	else
		ARCH="$arch" AUTH_TYPE="$auth_type" \
			REGION="$REGION" FAILOVERREGION="$FAILOVERREGION" \
			USE_ADDON="$USE_ADDON" ADDON_VERSION="$ADDON_VERSION" \
			POD_IDENTITY_ROLE_ARN="${POD_IDENTITY_ROLE_ARN:-}" \
			PRIVREPO="${PRIVREPO:-}" PRIVTAG="${PRIVTAG:-}" \
			bats integration.bats 2>&1 | tee "$log_file"
	fi
}

run_parallel() {
	for target in "$@"; do
		run_test "${target%%-*}" "${target#*-}" true &
		PIDS+=($!)
	done
	local failed=0
	for pid in "${PIDS[@]}"; do
		wait "$pid" || failed=1
	done
	return $failed
}

validate_image() {
	if [[ "$USE_ADDON" == "true" ]] || [[ -z "${PRIVREPO:-}" ]]; then
		return
	fi
	if [[ "$PRIVREPO" == *".dkr.ecr."*".amazonaws.com/"* ]]; then
		echo "Validating ECR image: $PRIVREPO"
		python3 test-manager.py validate-image
	fi
}

cleanup_cluster() {
	local name="integ-cluster-$1"
	local region="${REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
	if eksctl get cluster --name "$name" --region "$region" >/dev/null 2>&1; then
		echo "Deleting cluster $name..."
		eksctl delete cluster --name "$name" --parallel 25 || echo "⚠ Failed to delete $name (may need manual cleanup)"
	fi
}

cleanup_secrets() {
	echo "Cleaning up secrets and parameters..."
	detect_regions
	python3 test-manager.py cleanup-secrets
}

# --- Argument parsing ---

TEST_TARGET=""
CLEAN_TARGETS=""

if [[ $# -gt 0 ]] && [[ "$1" == "clean" ]]; then
	TEST_TARGET="clean"
	shift
	[[ $# -gt 0 ]] && [[ "$1" != "--"* ]] && { CLEAN_TARGETS="$1"; shift; }
elif [[ $# -gt 0 ]] && [[ "$1" != "--"* ]]; then
	TEST_TARGET="$1"
	shift
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--addon)   USE_ADDON=true; shift ;;
		--version) ADDON_VERSION="$2"; shift 2 ;;
		*)         echo "Error: Unknown argument '$1'"; exit 1 ;;
	esac
done

[[ -n "$ADDON_VERSION" ]] && [[ "$USE_ADDON" != "true" ]] && { echo "Error: --version requires --addon"; exit 1; }

# --- Validation (skip for clean) ---

if [[ "$TEST_TARGET" != "clean" ]]; then
	if target_needs_pod_identity "${TEST_TARGET:-}"; then
		if [[ -z "${POD_IDENTITY_ROLE_ARN:-}" ]]; then
			echo "Error: POD_IDENTITY_ROLE_ARN is required for pod-identity tests"
			exit 1
		fi
	fi

	if [[ "$USE_ADDON" != "true" ]] && [[ -z "${PRIVREPO:-}" ]]; then
		echo "Error: PRIVREPO environment variable is not set"
		exit 1
	fi
fi

# --- Execute ---

if [[ "$TEST_TARGET" == "clean" ]]; then
	detect_regions
	cleanup_secrets
	cleanup_stale_resources "${REGION}" $(resolve_targets "${CLEAN_TARGETS:-all}")
	exit 0
fi

detect_regions
targets=$(resolve_targets "${TEST_TARGET:-all}")

# Preflight: check tools, credentials, clean stale resources, verify VPC capacity
# shellcheck disable=SC2086
preflight "$REGION" $targets

validate_image

# Create secrets
python3 test-manager.py create-secrets

# Set up log directory
LOG_DIR="logs/$(date +'%Y-%m-%d_%H-%M-%S')"
mkdir -p "$LOG_DIR"
echo "Test logs: $LOG_DIR"

# Run tests
target_count=$(echo "$targets" | wc -w)

if [[ $target_count -eq 1 ]]; then
	run_test "${targets%%-*}" "${targets#*-}"
	rc=$?
else
	# shellcheck disable=SC2086
	run_parallel $targets
	rc=$?
fi

# Dump logs to stdout (for CI/GitHub Actions)
echo ""
echo "=== Test Results ==="
for f in "$LOG_DIR"/*.log; do
	[[ -f "$f" ]] || continue
	echo ""
	echo "--- $(basename "$f") ---"
	cat "$f"
done

exit $rc
