#!/bin/bash
#
# One-time setup for integration tests.
#
# Usage: ./setup.sh [deps|iam|all]
#
#   deps — Check that required CLI tools are installed
#   iam  — Create the IAM role needed for Pod Identity tests
#   all  — Both (default)
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export PATH="${PATH}:${SCRIPT_DIR}/tools/bats/bin:${SCRIPT_DIR}/tools:${APOLLO_ENVIRONMENT_ROOT:-}/bin"
ROLE_NAME="${POD_IDENTITY_ROLE_NAME:-pod-identity-role}"

# ============================================================
# Tool check
# ============================================================

# Check that all required CLI tools are installed; report optional ones.
setup_deps() {
    echo "Checking required tools..."
    local missing=()
    for tool in aws kubectl bats envsubst; do
        if command -v "$tool" &>/dev/null; then
            echo "  ✓ $tool ($(command -v "$tool"))"
        else
            missing+=("$tool")
            echo "  ✗ $tool"
        fi
    done
    # Optional tools — report presence but don't fail if missing
    for tool in eksctl helm; do
        if command -v "$tool" &>/dev/null; then
            echo "  ✓ $tool ($(command -v "$tool")) [optional]"
        else
            echo "  - $tool [not found, optional]"
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        echo ""
        echo "Missing required tools: ${missing[*]}"
        echo "  aws:      https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        echo "  kubectl:  https://kubernetes.io/docs/tasks/tools/"
        echo "  bats:     https://github.com/bats-core/bats-core"
        echo "  envsubst: Part of GNU gettext (brew install gettext / apt install gettext)"
        exit 1
    fi
    echo "✓ All required tools available"
}

# ============================================================
# Pod Identity IAM role
# ============================================================

# Creates an IAM role that EKS Pod Identity can assume. The role needs:
#   - Trust policy allowing pods.eks.amazonaws.com to assume it
#   - sts:TagSession (required by Pod Identity for session tagging)
#   - Read-only policies for Secrets Manager and SSM Parameter Store
setup_iam_role() {
    local partition
    partition=$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)
    echo "Setting up IAM role for Pod Identity (partition: $partition)..."

    if ! aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        aws iam create-role --role-name "$ROLE_NAME" --assume-role-policy-document '{
            "Version": "2012-10-17",
            "Statement": [{
                "Effect": "Allow",
                "Principal": {"Service": "pods.eks.amazonaws.com"},
                "Action": ["sts:AssumeRole", "sts:TagSession"]
            }]
        }' >/dev/null
        echo "✓ Created role: $ROLE_NAME"
    else
        echo "✓ Role exists: $ROLE_NAME"
    fi

    for policy in AmazonSSMReadOnlyAccess AWSSecretsManagerClientReadOnlyAccess; do
        aws iam attach-role-policy --role-name "$ROLE_NAME" \
            --policy-arn "arn:${partition}:iam::aws:policy/${policy}" 2>/dev/null || true
    done

    local role_arn
    role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
    echo ""
    echo "Run:  export POD_IDENTITY_ROLE_ARN=$role_arn"
}

# ============================================================
# Main
# ============================================================

cd "$SCRIPT_DIR"
case "${1:-all}" in
    deps) setup_deps ;;
    iam)  setup_iam_role ;;
    all)  setup_deps; setup_iam_role ;;
    *)    echo "Usage: ./setup.sh [deps|iam|all]"; exit 1 ;;
esac
