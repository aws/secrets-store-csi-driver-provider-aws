#!/bin/bash
#
# Setup script for integration tests
# Installs dependencies and configures IAM role for Pod Identity
#
# Usage: ./setup.sh [venv|iam|deps|all]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE_NAME="${POD_IDENTITY_ROLE_NAME:-pod-identity-role}"

get_partition() {
    aws sts get-caller-identity --query Arn --output text | cut -d: -f2
}

setup_deps() {
    echo "Installing dependencies..."
    
    if [[ "$(uname)" == "Darwin" ]]; then
        install_cmd="brew install"
        bats_pkg="bats-core"
    else
        if ! yum repolist enabled | grep -q epel; then
            echo "Enabling EPEL repository..."
            sudo yum install -y epel-release
        fi
        install_cmd="sudo yum install -y"
        bats_pkg="bats"
    fi
    
    for cmd_pkg in "bats:$bats_pkg" "parallel:parallel"; do
        cmd="${cmd_pkg%%:*}"
        pkg="${cmd_pkg##*:}"
        if ! command -v "$cmd" &>/dev/null; then
            echo "Installing $cmd..."
            $install_cmd "$pkg"
            echo "✓ Installed $cmd"
        else
            echo "✓ $cmd already installed"
        fi
    done
}

setup_venv() {
    echo "Setting up Python virtual environment..."
    if command -v uv &>/dev/null; then
        uv venv
        uv pip install boto3 argparse
    else
        python3 -m venv .venv
        .venv/bin/pip install boto3 argparse
    fi
    echo "✓ Python environment ready"
}

setup_iam_role() {
    local partition
    partition=$(get_partition)
    
    echo "Setting up IAM role for Pod Identity (partition: $partition)..."
    
    if ! aws iam get-role --role-name "$ROLE_NAME" &>/dev/null; then
        aws iam create-role \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document '{
                "Version": "2012-10-17",
                "Statement": [{
                    "Effect": "Allow",
                    "Principal": {"Service": "pods.eks.amazonaws.com"},
                    "Action": ["sts:AssumeRole", "sts:TagSession"]
                }]
            }' >/dev/null
        echo "✓ Created IAM role: $ROLE_NAME"
    else
        echo "✓ IAM role already exists: $ROLE_NAME"
    fi
    
    for policy in AmazonSSMReadOnlyAccess AWSSecretsManagerClientReadOnlyAccess; do
        policy_arn="arn:${partition}:iam::aws:policy/${policy}"
        aws iam attach-role-policy --role-name "$ROLE_NAME" --policy-arn "$policy_arn" 2>/dev/null || true
        echo "✓ Attached policy: $policy"
    done
    
    local role_arn
    role_arn=$(aws iam get-role --role-name "$ROLE_NAME" --query Role.Arn --output text)
    echo ""
    echo "Run this command to set the environment variable:"
    echo "  export POD_IDENTITY_ROLE_ARN=$role_arn"
}

cd "$SCRIPT_DIR"

case "${1:-all}" in
    deps) setup_deps ;;
    venv) setup_venv ;;
    iam) setup_iam_role ;;
    all) setup_deps; setup_venv; setup_iam_role ;;
    *) echo "Usage: ./setup.sh [deps|venv|iam|all]"; exit 1 ;;
esac
