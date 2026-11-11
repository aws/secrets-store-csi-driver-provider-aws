#!/bin/bash
#
# Creates or deletes the IAM the role chaining (assumeRoleArn) integration tests expect. Run this
# once when testing in your own account.
#
# Usage:
#   ./setup-role-chaining-iam.sh create <pod-identity-role-arn>
#   ./setup-role-chaining-iam.sh delete <pod-identity-role-arn>
#
# <pod-identity-role-arn> is POD_IDENTITY_ROLE_ARN from tests/README.md step 6.
#
# Resources (fixed names; integration.bats.template derives the ARNs from the account):
#   role   ascp-role-chaining-target       trusts the Pod Identity role and the per-run eksctl IRSA
#                                          roles; reads the AssumeRole* secrets and parameters
#   role   ascp-role-chaining-untrusted    trusts no cluster identity; used by the negative test
#   policy ascp-role-chaining-base-policy  sts:AssumeRole on the two roles; eksctl attaches it to the
#                                          IRSA role chaining service account
#   inline policy on the Pod Identity role  sts:AssumeRole and sts:TagSession on the two roles, and a
#                                          deny on the AssumeRole* objects, since README step 7 gives
#                                          that role read access to everything

set -euo pipefail

ACTION=${1:-}
POD_IDENTITY_ROLE_ARN=${2:-}
if [[ ( "$ACTION" != "create" && "$ACTION" != "delete" ) || -z "$POD_IDENTITY_ROLE_ARN" ]]; then
	echo "Usage: $0 create|delete <pod-identity-role-arn>" >&2
	exit 1
fi

REGION=us-west-2
FAILOVERREGION=us-east-2
ACCOUNT=$(aws sts get-caller-identity --query Account --output text)

TARGET=ascp-role-chaining-target
UNTRUSTED=ascp-role-chaining-untrusted
BASE_POLICY=ascp-role-chaining-base-policy
BASE_POLICY_ARN=arn:aws:iam::$ACCOUNT:policy/$BASE_POLICY
POD_IDENTITY_ROLE_NAME=${POD_IDENTITY_ROLE_ARN##*/}
POD_IDENTITY_INLINE_POLICY=ascp-role-chaining
ROLE_ARNS="\"arn:aws:iam::$ACCOUNT:role/$TARGET\", \"arn:aws:iam::$ACCOUNT:role/$UNTRUSTED\""
SECRET_ARNS="\"arn:aws:secretsmanager:$REGION:$ACCOUNT:secret:AssumeRole*\", \"arn:aws:secretsmanager:$FAILOVERREGION:$ACCOUNT:secret:AssumeRole*\""
PARAMETER_ARNS="\"arn:aws:ssm:$REGION:$ACCOUNT:parameter/AssumeRole*\", \"arn:aws:ssm:$FAILOVERREGION:$ACCOUNT:parameter/AssumeRole*\""

# The tests create the IRSA base role per run with `eksctl create iamserviceaccount --role-name`,
# one per IRSA cell, so the trust can name the exact ARNs. The roles come and go with the clusters,
# so the principal is the account root plus this condition (generate-test-files.py picks the names).
IRSA_BASE_ROLE_ARNS="\"arn:aws:iam::$ACCOUNT:role/eksctl-ascp-role-chaining-base-x64-irsa\", \"arn:aws:iam::$ACCOUNT:role/eksctl-ascp-role-chaining-base-arm-irsa\""

# Pod Identity session tags travel with the chained AssumeRole call, so the trust policy must
# allow sts:TagSession, and the tags can restrict which workload may assume the role.
target_trust_policy() {
	cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "IRSA",
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::$ACCOUNT:root"},
      "Action": "sts:AssumeRole",
      "Condition": {"ArnEquals": {"aws:PrincipalArn": [$IRSA_BASE_ROLE_ARNS]}}
    },
    {
      "Sid": "PodIdentity",
      "Effect": "Allow",
      "Principal": {"AWS": "$POD_IDENTITY_ROLE_ARN"},
      "Action": ["sts:AssumeRole", "sts:TagSession"],
      "Condition": {
        "StringEquals": {"aws:PrincipalTag/kubernetes-namespace": "kube-system"},
        "StringLike": {"aws:PrincipalTag/kubernetes-service-account": "assume-role-test-sa-*"}
      }
    }
  ]
}
EOF
}

# The provider never sends an external ID, so nothing in the cluster can assume this role.
untrusted_trust_policy() {
	cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": "arn:aws:iam::$ACCOUNT:root"},
    "Action": "sts:AssumeRole",
    "Condition": {"StringEquals": {"sts:ExternalId": "ascp-role-chaining-tests-never-sent"}}
  }]
}
EOF
}

target_permissions_policy() {
	cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"], "Resource": [$SECRET_ARNS]},
    {"Effect": "Allow", "Action": ["ssm:GetParameter", "ssm:GetParameters"], "Resource": [$PARAMETER_ARNS]}
  ]
}
EOF
}

base_policy() {
	cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{"Effect": "Allow", "Action": "sts:AssumeRole", "Resource": [$ROLE_ARNS]}]
}
EOF
}

pod_identity_inline_policy() {
	cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": ["sts:AssumeRole", "sts:TagSession"], "Resource": [$ROLE_ARNS]},
    {"Effect": "Deny", "Action": ["secretsmanager:GetSecretValue", "ssm:GetParameter", "ssm:GetParameters"], "Resource": [$SECRET_ARNS, $PARAMETER_ARNS]}
  ]
}
EOF
}

create_or_update_role() {
	local name=$1 trust=$2 description=$3
	if aws iam get-role --role-name "$name" >/dev/null 2>&1; then
		aws iam update-assume-role-policy --role-name "$name" --policy-document "$trust"
		echo "Updated trust policy: $name"
		return
	fi
	# Naming a role created seconds ago (README step 6) as a principal can fail with "Invalid
	# principal" until IAM catches up. Retry for about a minute.
	for attempt in $(seq 1 12); do
		if output=$(aws iam create-role --role-name "$name" --assume-role-policy-document "$trust" --description "$description" 2>&1); then
			echo "Created role: $name"
			return
		fi
		if [[ "$output" != *"Invalid principal"* || "$attempt" -eq 12 ]]; then
			echo "$output" >&2
			return 1
		fi
		echo "Principal not yet visible to IAM, retrying: $name"
		sleep 5
	done
}

delete_role() {
	local name=$1
	if ! aws iam get-role --role-name "$name" >/dev/null 2>&1; then
		echo "Role does not exist: $name"
		return
	fi
	for policy in $(aws iam list-role-policies --role-name "$name" --query 'PolicyNames[]' --output text); do
		aws iam delete-role-policy --role-name "$name" --policy-name "$policy"
	done
	aws iam delete-role --role-name "$name"
	echo "Deleted role: $name"
}

if [[ "$ACTION" == "create" ]]; then
	create_or_update_role "$TARGET" "$(target_trust_policy)" "ASCP integration tests: role chaining target"
	aws iam put-role-policy --role-name "$TARGET" --policy-name read-role-chaining-test-objects --policy-document "$(target_permissions_policy)"
	create_or_update_role "$UNTRUSTED" "$(untrusted_trust_policy)" "ASCP integration tests: role chaining negative case"

	# Managed policies are versioned, so this one is never updated in place; delete and create to change it.
	if aws iam get-policy --policy-arn "$BASE_POLICY_ARN" >/dev/null 2>&1; then
		echo "Policy already exists: $BASE_POLICY_ARN"
	else
		aws iam create-policy --policy-name "$BASE_POLICY" --policy-document "$(base_policy)" \
			--description "ASCP integration tests: lets the IRSA role chaining service account assume the test roles" >/dev/null
		echo "Created policy: $BASE_POLICY_ARN"
	fi

	aws iam put-role-policy --role-name "$POD_IDENTITY_ROLE_NAME" --policy-name "$POD_IDENTITY_INLINE_POLICY" --policy-document "$(pod_identity_inline_policy)"
	echo "Updated inline policy $POD_IDENTITY_INLINE_POLICY on $POD_IDENTITY_ROLE_ARN"
else
	delete_role "$TARGET"
	delete_role "$UNTRUSTED"
	if aws iam get-policy --policy-arn "$BASE_POLICY_ARN" >/dev/null 2>&1; then
		for role in $(aws iam list-entities-for-policy --policy-arn "$BASE_POLICY_ARN" --query 'PolicyRoles[].RoleName' --output text); do
			aws iam detach-role-policy --role-name "$role" --policy-arn "$BASE_POLICY_ARN"
		done
		aws iam delete-policy --policy-arn "$BASE_POLICY_ARN"
		echo "Deleted policy: $BASE_POLICY_ARN"
	fi
	aws iam delete-role-policy --role-name "$POD_IDENTITY_ROLE_NAME" --policy-name "$POD_IDENTITY_INLINE_POLICY" 2>/dev/null || true
	echo "Removed inline policy $POD_IDENTITY_INLINE_POLICY from $POD_IDENTITY_ROLE_ARN"
fi
