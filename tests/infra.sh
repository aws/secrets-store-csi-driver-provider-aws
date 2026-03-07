#!/bin/bash
#
# Pluggable infrastructure backend for integration tests.
#
# Provides a uniform interface for creating and tearing down EKS test clusters
# with two interchangeable backends:
#
#   cfn    — Fully declarative via CloudFormation (cluster + resources).
#            No eksctl dependency. Best for constrained environments.
#
#   eksctl — Cluster creation via eksctl, test resources via CloudFormation.
#            Best for quick local iteration and GitHub Actions.
#
# Both backends use CloudFormation for test secrets and SSM parameters
# (cfn/test-resources.yaml), ensuring resource definitions are always
# declarative and consistent.
#
# Usage: infra.sh <command> [args...]
#
# Commands:
#   deploy <suffix>            Create cluster + test resources for a target
#   delete <suffix>            Tear down cluster + test resources for a target
#   cleanup-stale <suffix...>  Remove leftover resources from previous runs
#   write-kubeconfig <suffix>  Write kubeconfig for an existing cluster
#   print-regions              Output REGION/FAILOVERREGION as shell exports
#
# Environment:
#   INFRA_BACKEND         cfn | eksctl | auto (default: auto — eksctl if available, else cfn)
#   REGION                Primary AWS region (auto-detected if unset)
#   FAILOVERREGION        Failover AWS region (auto-detected if unset)
#   RESOURCE_PREFIX       Inserted into test resource names for collision avoidance (default: "")
#   POD_IDENTITY_ROLE_ARN IAM role ARN for Pod Identity tests
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ============================================================
# Configuration
# ============================================================

INFRA_BACKEND="${INFRA_BACKEND:-auto}"

# Stack naming conventions:
#   integ-cluster-<suffix>     — EKS cluster (cfn backend only; eksctl manages its own stacks)
#   integ-resources-<suffix>   — test secrets/params in primary region
#   integ-failover-<suffix>    — test secrets/params in failover region
CLUSTER_STACK_PREFIX="integ-cluster"
RESOURCES_STACK_PREFIX="integ-resources"
FAILOVER_STACK_PREFIX="integ-failover"

# Short alias for RESOURCE_PREFIX, used in CFN parameter overrides.
P="${RESOURCE_PREFIX:-}"

# ============================================================
# Region detection
# ============================================================

# Determine primary and failover regions. Uses env vars if set, otherwise
# reads the AWS CLI default region and picks a same-geography failover.
detect_regions() {
	if [[ -n "${REGION:-}" && -n "${FAILOVERREGION:-}" ]]; then return; fi
	REGION="${REGION:-$(aws configure get region 2>/dev/null || echo us-west-2)}"
	if [[ -z "${FAILOVERREGION:-}" ]]; then
		# Pick the first region in the same geography (e.g. us-east-2 for us-west-2)
		local prefix="${REGION%%-*}"
		FAILOVERREGION=$(aws ec2 describe-regions --all-regions --query \
			"Regions[?starts_with(RegionName,'${prefix}') && RegionName!='${REGION}'].RegionName | sort(@) | [0]" \
			--output text --region "$REGION" 2>/dev/null) || true
		if [[ -z "$FAILOVERREGION" || "$FAILOVERREGION" == "None" ]]; then
			FAILOVERREGION="$REGION"
		fi
	fi
}

# ============================================================
# CloudFormation helpers
# ============================================================

# Safely delete a CFN stack, handling all intermediate states:
#   - Waits for any IN_PROGRESS operation to finish
#   - Continues a failed rollback so the stack becomes deletable
#   - Disables termination protection (test stacks shouldn't have it, but just in case)
#   - Deletes and waits for completion
wait_and_delete_stack() {
	local stack="$1" region="$2" status
	status=$(aws cloudformation describe-stacks --stack-name "$stack" --region "$region" \
		--query 'Stacks[0].StackStatus' --output text 2>/dev/null) || return 0
	if [[ "$status" == "DELETE_COMPLETE" ]]; then return 0; fi

	# Wait for any in-progress operation before attempting delete.
	# REVIEW_IN_PROGRESS means a changeset is awaiting approval — it won't resolve
	# on its own, so we delete the stack directly instead of waiting.
	while [[ "$status" == *"IN_PROGRESS"* && "$status" != "REVIEW_IN_PROGRESS" ]]; do
		echo "⏳ $stack ($status)..."; sleep 10
		status=$(aws cloudformation describe-stacks --stack-name "$stack" --region "$region" \
			--query 'Stacks[0].StackStatus' --output text 2>/dev/null) || return 0
	done

	# A stuck rollback must be continued before the stack can be deleted
	if [[ "$status" == *"ROLLBACK_FAILED"* ]]; then
		aws cloudformation continue-update-rollback --stack-name "$stack" --region "$region" 2>/dev/null || true
		aws cloudformation wait stack-rollback-complete --stack-name "$stack" --region "$region" 2>/dev/null || true
	fi

	aws cloudformation update-termination-protection --no-enable-termination-protection \
		--stack-name "$stack" --region "$region" >/dev/null 2>&1 || true
	aws cloudformation delete-stack --stack-name "$stack" --region "$region" >/dev/null 2>&1 || true
	aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$region" 2>/dev/null || true

	# If the stack landed in DELETE_FAILED, force-delete by retaining the
	# resources that blocked deletion. This abandons those resources but
	# unblocks the stack so subsequent deploys don't hit AlreadyExistsException.
	status=$(aws cloudformation describe-stacks --stack-name "$stack" --region "$region" \
		--query 'Stacks[0].StackStatus' --output text 2>/dev/null) || return 0
	if [[ "$status" == "DELETE_FAILED" ]]; then
		echo "⚠ $stack in DELETE_FAILED — retrying with --retain-resources"
		local retain
		retain=$(aws cloudformation describe-stack-resources --stack-name "$stack" --region "$region" \
			--query 'StackResources[?ResourceStatus!=`DELETE_COMPLETE`].LogicalResourceId' --output text 2>/dev/null)
		cleanup_retained_eips "$stack" "$region"
		aws cloudformation delete-stack --stack-name "$stack" --region "$region" \
			--retain-resources $retain >/dev/null 2>&1 || true
		aws cloudformation wait stack-delete-complete --stack-name "$stack" --region "$region" 2>/dev/null || true
	fi
}

# Clean up Elastic IPs and NAT Gateways retained after a force-delete.
# When --retain-resources abandons VPC resources, EIPs continue to incur charges.
cleanup_retained_eips() {
	local stack="$1" region="$2" vpc_id
	vpc_id=$(aws cloudformation describe-stack-resources --stack-name "$stack" --region "$region" \
		--query "StackResources[?LogicalResourceId=='VPC'].PhysicalResourceId" --output text 2>/dev/null) || return 0
	[[ -n "$vpc_id" && "$vpc_id" != "None" ]] || return 0

	local nat_gws
	nat_gws=$(aws ec2 describe-nat-gateways --filter "Name=vpc-id,Values=$vpc_id" \
		--query "NatGateways[?State!='deleted'].[NatGatewayId,NatGatewayAddresses[0].AllocationId]" \
		--output text --region "$region" 2>/dev/null) || return 0
	local deleted_any=false
	while read -r ngw alloc_id; do
		[[ -n "$ngw" ]] || continue
		echo "Deleting NAT Gateway $ngw and releasing EIP $alloc_id"
		aws ec2 delete-nat-gateway --nat-gateway-id "$ngw" --region "$region" >/dev/null 2>&1 || true
		deleted_any=true
	done <<< "$nat_gws"
	# Wait for NAT Gateways to release EIPs, then release them
	if [[ "$deleted_any" == "true" ]]; then sleep 30; fi
	while read -r ngw alloc_id; do
		[[ -n "$alloc_id" && "$alloc_id" != "None" ]] || continue
		aws ec2 release-address --allocation-id "$alloc_id" --region "$region" >/dev/null 2>&1 || true
	done <<< "$nat_gws"
}

# Deploy test-resources.yaml to both primary and failover regions.
# Used by both backends — test resources are always managed via CFN.
# Before deploying, removes any pre-existing resources with the same names
# that might have been created outside of CFN (e.g. by a previous test run
# using imperative AWS CLI calls). CFN cannot create resources that already exist.
deploy_test_resources() {
	local suffix="$1"; detect_regions
	local tpl="$SCRIPT_DIR/cfn/test-resources.yaml"
	local params=("Suffix=$suffix" "ResourcePrefix=$P")

	# Clean up any pre-existing resources that would conflict with CFN creation
	cleanup_conflicting_resources "$suffix" "$REGION"
	cleanup_conflicting_resources "$suffix" "$FAILOVERREGION"

	echo "Deploying test resources in $REGION and $FAILOVERREGION..."
	local expires_at
	expires_at=$(date -u -d '+4 hours' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v+4H '+%Y-%m-%dT%H:%M:%SZ')
	aws cloudformation deploy --template-file "$tpl" \
		--stack-name "${RESOURCES_STACK_PREFIX}-${suffix}" \
		--parameter-overrides "${params[@]}" \
		--region "$REGION" --no-fail-on-empty-changeset \
		--tags "ExpiresAt=$expires_at" "ManagedBy=integ-tests" &
	local pid_primary=$!

	aws cloudformation deploy --template-file "$tpl" \
		--stack-name "${FAILOVER_STACK_PREFIX}-${suffix}" \
		--parameter-overrides "${params[@]}" \
		--region "$FAILOVERREGION" --no-fail-on-empty-changeset \
		--tags "ExpiresAt=$expires_at" "ManagedBy=integ-tests" &
	local pid_failover=$!

	local failed=0
	if ! wait "$pid_primary"; then echo "⚠ Test resource deploy failed in $REGION"; failed=1; fi
	if ! wait "$pid_failover"; then echo "⚠ Test resource deploy failed in $FAILOVERREGION"; failed=1; fi
	if [[ $failed -eq 1 ]]; then return 1; fi
}

# Remove secrets/parameters that exist outside of CFN management.
# This handles the case where resources were created by a previous test run
# using imperative CLI calls (e.g. the old Python test-manager) and would
# cause CFN's ResourceExistenceCheck to fail.
cleanup_conflicting_resources() {
	local suffix="$1" region="$2"
	source "$SCRIPT_DIR/resource-names.env"
	for name in "${SECRET_NAMES[@]}"; do
		aws secretsmanager delete-secret --secret-id "$name" --force-delete-without-recovery \
			--region "$region" >/dev/null 2>&1 || true
	done
	for name in "${PARAM_NAMES[@]}"; do
		aws ssm delete-parameter --name "$name" --region "$region" >/dev/null 2>&1 || true
	done
}

# Delete test resource stacks from both regions (in parallel).
# Also cleans up any resources that exist outside of CFN management.
delete_test_resources() {
	local suffix="$1"; detect_regions
	echo "Cleaning up test secrets/parameters for $suffix..."
	cleanup_conflicting_resources "$suffix" "$REGION"
	cleanup_conflicting_resources "$suffix" "$FAILOVERREGION"
	echo "Deleting test resource stacks for $suffix..."
	wait_and_delete_stack "${RESOURCES_STACK_PREFIX}-${suffix}" "$REGION" &
	local pid1=$!
	wait_and_delete_stack "${FAILOVER_STACK_PREFIX}-${suffix}" "$FAILOVERREGION" &
	local pid2=$!
	wait "$pid1" "$pid2"
	echo "✓ Test resources deleted for $suffix"
}

# ============================================================
# Kubeconfig (shared by both backends)
# ============================================================

# Both backends use the same cluster naming convention (integ-cluster-<suffix>),
# so kubeconfig generation is identical regardless of how the cluster was created.
write_kubeconfig() {
	local suffix="$1" kc="/tmp/integ-kubeconfig-${suffix}"
	detect_regions
	aws eks update-kubeconfig \
		--name "${CLUSTER_STACK_PREFIX}-${suffix}" --region "$REGION" \
		--kubeconfig "$kc" 2>/dev/null
	chmod 600 "$kc"
}

# ============================================================
# CFN backend
# ============================================================
# Deploys three stacks per target:
#   1. cluster-stack.yaml (primary region) — VPC, EKS, nodes, auth
#   2. test-resources.yaml (primary region) — test secrets/params
#   3. test-resources.yaml (failover region) — replica of test secrets/params

# Deploy cluster stack and test resource stacks.
cfn_deploy() {
	local suffix="$1"; detect_regions
	local stack="${CLUSTER_STACK_PREFIX}-${suffix}" auth_type="${suffix#*-}"

	echo "Deploying $stack (auth=$auth_type, auto mode)..."
	local params=("ClusterName=$stack" "Suffix=$suffix" "AuthType=$auth_type" "KubernetesVersion=${EKS_VERSION:-1.35}")
	if [[ "$auth_type" == "pod-identity" && -n "${POD_IDENTITY_ROLE_ARN:-}" ]]; then
		params+=("PodIdentityRoleArn=$POD_IDENTITY_ROLE_ARN")
	fi

	local expires_at
	expires_at=$(date -u -d '+4 hours' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null \
		|| date -u -v+4H '+%Y-%m-%dT%H:%M:%SZ')
	aws cloudformation deploy --template-file "$SCRIPT_DIR/cfn/cluster-stack.yaml" \
		--stack-name "$stack" --parameter-overrides "${params[@]}" \
		--capabilities CAPABILITY_IAM --region "$REGION" --no-fail-on-empty-changeset \
		--tags "ExpiresAt=$expires_at" "ManagedBy=integ-tests"

	deploy_test_resources "$suffix"
	echo "✓ Deployed $suffix"
}

# Delete cluster stack and test resource stacks.
cfn_delete() {
	local suffix="$1"; detect_regions
	echo "Deleting stacks for $suffix..."
	wait_and_delete_stack "${CLUSTER_STACK_PREFIX}-${suffix}" "$REGION" &
	local cluster_pid=$!
	delete_test_resources "$suffix"
	local failed=0
	if ! wait "$cluster_pid"; then
		echo "⚠ Cluster stack deletion failed for $suffix"
		failed=1
	fi
	if [[ $failed -eq 0 ]]; then
		echo "✓ Deleted $suffix"
	else
		echo "✗ Deletion incomplete for $suffix"
		return 1
	fi
}

# Remove leftover stacks from previous test runs.
cfn_cleanup_stale() {
	detect_regions
	for suffix in "$@"; do
		for sr in \
			"${CLUSTER_STACK_PREFIX}-${suffix}:${REGION}" \
			"${RESOURCES_STACK_PREFIX}-${suffix}:${REGION}" \
			"${FAILOVER_STACK_PREFIX}-${suffix}:${FAILOVERREGION}"; do
			local stack="${sr%%:*}" region="${sr#*:}" status
			status=$(aws cloudformation describe-stacks --stack-name "$stack" --region "$region" \
				--query 'Stacks[0].StackStatus' --output text 2>/dev/null) || continue
			if [[ "$status" != "DELETE_COMPLETE" ]]; then
				echo "⚠ Cleaning up $stack ($status)..."
				wait_and_delete_stack "$stack" "$region"
			fi
		done
	done
}

# ============================================================
# eksctl backend
# ============================================================
# Creates clusters imperatively via eksctl. Test secrets and SSM parameters
# are still managed via CloudFormation (test-resources.yaml) for consistency.

# Create cluster via eksctl with auto mode and deploy test resource stacks.
eksctl_deploy() {
	local suffix="$1"; detect_regions
	local cluster="${CLUSTER_STACK_PREFIX}-${suffix}"

	echo "Creating EKS cluster $cluster via eksctl (auto mode)..."
	local version_flag=""
	if [[ -n "${EKS_VERSION:-}" ]]; then version_flag="--version ${EKS_VERSION}"; fi
	eksctl create cluster --name "$cluster" --region "$REGION" --enable-auto-mode \
		$version_flag --kubeconfig="/tmp/integ-kubeconfig-${suffix}"

	deploy_test_resources "$suffix"
	echo "✓ Deployed $suffix"
}

# Delete test resource stacks and the eksctl cluster.
eksctl_delete() {
	local suffix="$1"; detect_regions
	delete_test_resources "$suffix"
	local cluster="${CLUSTER_STACK_PREFIX}-${suffix}"
	echo "Deleting cluster ${cluster}..."
	eksctl delete cluster --name "$cluster" --region "$REGION" --wait --force 2>/dev/null || true

	# eksctl delete can fail partway through, leaving CFN stacks behind.
	# Fall back to direct CFN deletion for any orphaned eksctl stacks.
	local sn
	aws cloudformation list-stacks --region "$REGION" \
		--query "StackSummaries[?starts_with(StackName,'eksctl-${cluster}') && StackStatus!='DELETE_COMPLETE'].[StackName]" \
		--output text 2>/dev/null | while read -r sn; do
		if [[ -n "$sn" ]]; then
			echo "⚠ Cleaning up orphaned stack $sn..."
			wait_and_delete_stack "$sn" "$REGION"
		fi
	done
	echo "✓ Deleted $suffix"
}

# Remove leftover EKS clusters, orphaned eksctl CFN stacks, and test resource stacks.
eksctl_cleanup_stale() {
	detect_regions
	for suffix in "$@"; do
		local name="${CLUSTER_STACK_PREFIX}-${suffix}" status

		# Clean up the EKS cluster itself
		status=$(aws eks describe-cluster --name "$name" --region "$REGION" \
			--query 'cluster.status' --output text 2>/dev/null) || status=""
		if [[ "$status" == "DELETING" ]]; then
			echo "⏳ Cluster $name is deleting, waiting..."
			aws eks wait cluster-deleted --name "$name" --region "$REGION" 2>/dev/null || true
		elif [[ -n "$status" ]]; then
			echo "⚠ Cluster $name exists ($status), deleting..."
			eksctl delete cluster --name "$name" --region "$REGION" --wait 2>/dev/null || true
		fi

		# eksctl creates its own CFN stacks (eksctl-<cluster>-cluster, eksctl-<cluster>-nodegroup-*)
		# that can be orphaned if eksctl delete fails partway through
		aws cloudformation list-stacks --region "$REGION" \
			--query "StackSummaries[?starts_with(StackName,'eksctl-${name}') && StackStatus!='DELETE_COMPLETE'].[StackName]" \
			--output text 2>/dev/null | while read -r sn; do
			if [[ -n "$sn" ]]; then wait_and_delete_stack "$sn" "$REGION"; fi
		done

		# Clean up test resource stacks
		for sr in "${RESOURCES_STACK_PREFIX}-${suffix}:${REGION}" "${FAILOVER_STACK_PREFIX}-${suffix}:${FAILOVERREGION}"; do
			local stack="${sr%%:*}" region="${sr#*:}"
			wait_and_delete_stack "$stack" "$region"
		done
	done
}

# ============================================================
# Dispatch
# ============================================================

case "${1:-}" in
	print-regions)    detect_regions; echo "export REGION=\"$REGION\" FAILOVERREGION=\"$FAILOVERREGION\"" ;;
	deploy)           "${INFRA_BACKEND}_deploy" "$2" ;;
	delete)           "${INFRA_BACKEND}_delete" "$2" ;;
	cleanup-stale)    shift; "${INFRA_BACKEND}_cleanup_stale" "$@" ;;
	write-kubeconfig) write_kubeconfig "$2" ;;
	*)                echo "Usage: infra.sh <deploy|delete|cleanup-stale|write-kubeconfig|print-regions> [args...]"; exit 1 ;;
esac
