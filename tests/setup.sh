#!/bin/bash
#
# Setup script for integration tests.
# Usage: ./setup.sh [deps|venv|iam|all]
#

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLE_NAME="${POD_IDENTITY_ROLE_NAME:-pod-identity-role}"

get_partition() {
    aws sts get-caller-identity --query Arn --output text | cut -d: -f2
}

setup_deps() {
    echo "Checking required tools..."

    local missing=()
    for tool in aws eksctl kubectl bats envsubst python3; do
        if command -v "$tool" &>/dev/null; then
            echo "  ✓ $tool"
        else
            missing+=("$tool")
            echo "  ✗ $tool"
        fi
    done

    # bats can be auto-installed
    if [[ " ${missing[*]} " == *" bats "* ]]; then
        echo ""
        echo "Installing bats..."
        if [[ "$(uname)" == "Darwin" ]]; then
            brew install bats-core
        elif command -v apt-get &>/dev/null; then
            sudo apt-get install -y bats
        elif command -v yum &>/dev/null; then
            yum repolist enabled 2>/dev/null | grep -q epel || sudo yum install -y epel-release
            sudo yum install -y bats
        else
            echo "Error: Install bats manually: https://github.com/bats-core/bats-core"
            exit 1
        fi
        echo "  ✓ bats (installed)"
        missing=("${missing[@]/bats}")
    fi

    # Remove empty entries
    local still_missing=()
    for tool in "${missing[@]}"; do
        [[ -n "$tool" ]] && still_missing+=("$tool")
    done

    if [[ ${#still_missing[@]} -gt 0 ]]; then
        echo ""
        echo "Missing tools that must be installed manually: ${still_missing[*]}"
        echo "  aws:      https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html"
        echo "  eksctl:   https://eksctl.io/installation/"
        echo "  kubectl:  https://kubernetes.io/docs/tasks/tools/"
        echo "  envsubst: Part of GNU gettext (brew install gettext / apt install gettext)"
        exit 1
    fi

    echo "✓ All required tools available"
}

setup_venv() {
    echo "Setting up Python virtual environment..."
    if command -v uv &>/dev/null; then
        uv venv
        uv pip install boto3
    else
        python3 -m venv .venv
        .venv/bin/pip install boto3
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
    echo "Set the environment variable:"
    echo "  export POD_IDENTITY_ROLE_ARN=$role_arn          # bash/zsh"
    echo "  \$env.POD_IDENTITY_ROLE_ARN = '$role_arn'        # nushell"
}

cd "$SCRIPT_DIR"

case "${1:-all}" in
    deps) setup_deps ;;
    venv) setup_venv ;;
    iam)  setup_iam_role ;;
    all)  setup_deps; setup_venv; setup_iam_role ;;
    *)    echo "Usage: ./setup.sh [deps|venv|iam|all]"; exit 1 ;;
esac
