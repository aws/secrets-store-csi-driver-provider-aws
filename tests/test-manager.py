#!/usr/bin/env python3

import argparse
import os
import sys

import boto3
import botocore.exceptions

CYAN = "\033[36m"
RESET = "\033[0m"

CONFIGS = {
    name: {
        "ARCH": arch,
        "AUTH_TYPE": auth,
        "NODE_TYPE_VAR": f"NODE_TYPE_{arch.upper()}_{auth.upper().replace('-', '_')}",
        "DEFAULT_NODE_TYPE": "m6g.large" if arch == "arm" else "m5.large",
        "KUBECONFIG_VAR": f"KUBECONFIG_FILE_{arch.upper()}_{auth.upper().replace('-', '_')}",
        "LOG_COLOR": color,
        "COLOR_CODE": code,
    }
    for name, arch, auth, color, code in [
        ("x64-irsa", "x64", "irsa", "CYAN", "36"),
        ("x64-pod-identity", "x64", "pod-identity", "MAGENTA", "35"),
        ("arm-irsa", "arm", "irsa", "BLUE", "34"),
        ("arm-pod-identity", "arm", "pod-identity", "YELLOW", "33"),
    ]
}

REGION, FAILOVERREGION = (
    os.environ.get("REGION", "us-west-2"),
    os.environ.get("FAILOVERREGION", "us-east-2"),
)
secretsmanager = {
    r: boto3.client("secretsmanager", region_name=r) for r in [REGION, FAILOVERREGION]
}
ssm = {r: boto3.client("ssm", region_name=r) for r in [REGION, FAILOVERREGION]}

ARGS = None


def aws_operation(client, operation, name, region, exists_code, **kwargs):
    try:
        print(f"  {operation}: {name} in {region}")
        getattr(client[region], operation)(**kwargs)
    except botocore.exceptions.ClientError as e:
        if e.response["Error"]["Code"] == exists_code:
            print(f"  Already exists/not found: {name} in {region}")
        else:
            raise


def manage_resources(arch, auth_type, action):
    suffix = f"{arch}-{auth_type}"
    print(
        f"{'Creating' if action == 'create' else 'Cleaning up'} resources for {suffix}..."
    )

    resources = {
        "secrets": [
            ("SecretsManagerTest1", "SecretsManagerTest1Value"),
            ("SecretsManagerTest2", "SecretsManagerTest2Value"),
            ("SecretsManagerSync", "SecretUser"),
            ("SecretsManagerRotationTest", "BeforeRotation"),
            (
                "secretsManagerJson",
                '{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}',
            ),
        ],
        "parameters": [
            ("ParameterStoreTest1", "ParameterStoreTest1Value"),
            ("ParameterStoreTestWithLongName", "ParameterStoreTest2Value"),
            ("ParameterStoreRotationTest", "BeforeRotation"),
            (
                "jsonSsm",
                '{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}',
            ),
        ],
    }

    for region in [REGION, FAILOVERREGION]:
        for base_name, value in resources["secrets"]:
            name = f"{base_name}-{suffix}"
            if action == "create":
                aws_operation(
                    secretsmanager,
                    "create_secret",
                    name,
                    region,
                    "ResourceExistsException",
                    Name=name,
                    SecretString=value,
                )
            else:
                aws_operation(
                    secretsmanager,
                    "delete_secret",
                    name,
                    region,
                    "",
                    SecretId=name,
                    ForceDeleteWithoutRecovery=True,
                )

        for base_name, value in resources["parameters"]:
            name = f"{base_name}-{suffix}"
            if action == "create":
                aws_operation(
                    ssm,
                    "put_parameter",
                    name,
                    region,
                    "ParameterAlreadyExists",
                    Name=name,
                    Value=value,
                    Type="SecureString",
                    Overwrite=False,
                )
            else:
                aws_operation(
                    ssm,
                    "delete_parameter",
                    name,
                    region,
                    "ParameterNotFound",
                    Name=name,
                )


def get_auth_setup(arch: str, auth_type: str) -> str:
    sa_name = f"basic-test-mount-sa-{arch}-{auth_type}"
    if auth_type == "irsa":
        return f"""	log "Associating IAM OIDC provider"
    eksctl utils associate-iam-oidc-provider --name $CLUSTER_NAME --approve --region $REGION >&3 2>&1

    log "Creating IAM service account for IRSA"
    eksctl create iamserviceaccount \\
        --name {sa_name} \\
        --namespace $NAMESPACE \\
        --cluster $CLUSTER_NAME \\
        --attach-policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess \\
        --attach-policy-arn arn:aws:iam::aws:policy/AWSSecretsManagerClientReadOnlyAccess \\
        --override-existing-serviceaccounts \\
        --approve \\
        --region $REGION >&3 2>&1"""

    return f"""	log "Creating EKS Pod Identity addon"
    eksctl create addon --name eks-pod-identity-agent --cluster $CLUSTER_NAME --region $REGION >&3 2>&1

    log "Creating Pod Identity association"
    eksctl create podidentityassociation \\
        --cluster $CLUSTER_NAME \\
        --namespace $NAMESPACE \\
        --region $REGION \\
        --service-account-name {sa_name} \\
        --role-arn $POD_IDENTITY_ROLE_ARN \\
        --create-service-account true >&3 2>&1"""


def replace_template_vars(template_file, output_file, config):
    with open(template_file, encoding="utf-8") as f:
        content = f.read()

    replacements = {
        **{f"{{{{{k}}}}}": v for k, v in config.items()},
        "{{AUTH_SETUP}}": get_auth_setup(config["ARCH"], config["AUTH_TYPE"]),
        "{{INSTALL_METHOD}}": get_install_method(),
        "{{POD_IDENTITY_PARAM}}": '\n    usePodIdentity: "true"'
        if config["AUTH_TYPE"] == "pod-identity"
        else "",
        "{{PRIVREPO_CHECK}}": ""
        if ARGS.addon
        else """if [[ -z "${PRIVREPO}" ]]; then
	echo "Error: PRIVREPO is not specified" >&2
	return 1
fi""",
        "{{INSTALL_PROVIDER_TEST}}": ""
        if ARGS.addon
        else """@test "Install aws provider" {
	log "Installing AWS provider"

	envsubst < $PROVIDER_YAML | kubectl --kubeconfig=${{KUBECONFIG_VAR}} apply -f -
	cmd="kubectl --kubeconfig=${{KUBECONFIG_VAR}} --namespace $NAMESPACE wait --for=condition=Ready --timeout=60s pod -l app=csi-secrets-store-provider-aws"
	wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

	PROVIDER_POD=$(kubectl --kubeconfig=${{KUBECONFIG_VAR}} --namespace $NAMESPACE get pod -l app=csi-secrets-store-provider-aws -o jsonpath="{.items[0].metadata.name}")
	run kubectl --kubeconfig=${{KUBECONFIG_VAR}} --namespace $NAMESPACE get pod/$PROVIDER_POD
	assert_success

	log "AWS provider installation completed"
}""",
    }

    for old, new in replacements.items():
        content = content.replace(old, new)

    with open(output_file, "w", encoding="utf-8") as f:
        f.write(content)


def get_install_method() -> str:
    if ARGS.addon:
        version_flag = f" --addon-version {ARGS.version}" if ARGS.version else ""
        return f"""	log "Installing AWS Secrets Store CSI Driver Provider via EKS addon"
	aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name aws-secrets-store-csi-driver-provider --configuration-values "file://addon_config_values.yaml"{version_flag} --region $REGION >&3 2>&1"""

    return """	log "Adding secrets-store-csi-driver Helm repository"
	helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts >&3 2>&1

	log "Installing secrets-store-csi-driver via Helm"
	helm --kubeconfig=${{KUBECONFIG_VAR}} --namespace=$NAMESPACE install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver --set enableSecretRotation=true --set rotationPollInterval=15s --set syncSecret.enabled=true >&3 2>&1"""


def main():
    global ARGS
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "action",
        nargs="?",
        default="default",
        choices=[
            "create-secrets",
            "cleanup-secrets",
            "cleanup-files",
            "generate-files",
            "validate-image",
            "default",
        ],
    )
    parser.add_argument("--addon", action="store_true")
    parser.add_argument("--version")
    ARGS = parser.parse_args()

    if ARGS.action == "validate-image":
        image_uri = os.environ.get("PRIVREPO")
        if not image_uri:
            print("Error: PRIVREPO environment variable not set")
            sys.exit(1)

        # Parse ECR URI: account.dkr.ecr.region.amazonaws.com/repo or account.dkr.ecr.region.amazonaws.com/repo:tag
        import re

        match = re.match(
            r"(\d+)\.dkr\.ecr\.([^.]+)\.amazonaws\.com/([^:]+)(?::(.+))?", image_uri
        )
        if not match:
            print(f"Error: Invalid ECR image URI format: {image_uri}")
            sys.exit(1)

        account, region, repo, tag = match.groups()

        ecr = boto3.client("ecr", region_name=region)
        try:
            # If no tag specified, get the latest image
            if tag:
                response = ecr.describe_images(
                    repositoryName=repo, imageIds=[{"imageTag": tag}]
                )
            else:
                response = ecr.describe_images(repositoryName=repo, maxResults=1)

            if response["imageDetails"]:
                image = response["imageDetails"][0]
                pushed_at = image["imagePushedAt"]
                digest = image["imageDigest"]
                image_tags = image.get("imageTags", ["<untagged>"])
                display_uri = f"{image_uri}:{image_tags[0]}" if not tag else image_uri
                print(f"✓ Image validated: {display_uri}")
                print(f"  Digest: {digest}")
                print(f"  Pushed at: {pushed_at}")
            else:
                print(f"Error: No images found in repository: {image_uri}")
                sys.exit(1)
        except ecr.exceptions.RepositoryNotFoundException:
            print(f"Error: Repository not found: {repo}")
            sys.exit(1)
        except Exception as e:
            print(f"Error validating image: {e}")
            sys.exit(1)
        return

    if ARGS.action == "cleanup-files":
        files = [
            "x64-irsa.bats",
            "x64-pod-identity.bats",
            "arm-irsa.bats",
            "arm-pod-identity.bats",
            "BasicTestMountSPC-x64-irsa.yaml",
            "BasicTestMountSPC-x64-pod-identity.yaml",
            "BasicTestMountSPC-arm-irsa.yaml",
            "BasicTestMountSPC-arm-pod-identity.yaml",
            "BasicTestMount-x64-irsa.yaml",
            "BasicTestMount-x64-pod-identity.yaml",
            "BasicTestMount-arm-irsa.yaml",
            "BasicTestMount-arm-pod-identity.yaml",
        ]
        for f in files:
            if os.path.exists(f):
                os.remove(f)
                print(f"Removed {f}")
        print("Generated files cleaned up")
        return

    if ARGS.action in ["create-secrets", "cleanup-secrets"]:
        op = "create" if ARGS.action == "create-secrets" else "cleanup"
        print(
            f"{'Creating' if op == 'create' else 'Cleaning up'} secrets for all test configurations..."
        )
        for config in CONFIGS.values():
            manage_resources(config["ARCH"], config["AUTH_TYPE"], op)
        print(
            f"All secrets {'created' if op == 'create' else 'cleaned up'} successfully"
        )
        return

    if ARGS.action != "generate-files":
        for config in CONFIGS.values():
            manage_resources(config["ARCH"], config["AUTH_TYPE"], "create")

    for name, config in CONFIGS.items():
        arch, auth = config["ARCH"], config["AUTH_TYPE"]
        replace_template_vars("integration.bats.template", f"{name}.bats", config)
        replace_template_vars(
            "BasicTestMountSPC.yaml.template",
            f"BasicTestMountSPC-{arch}-{auth}.yaml",
            config,
        )
        replace_template_vars(
            "BasicTestMount.yaml.template", f"BasicTestMount-{arch}-{auth}.yaml", config
        )

    print(
        f"\nAll test files generated successfully\n"
        f"{CYAN}Usage:\n"
        f"  ./test-manager.py                 # Generate files and create secrets\n"
        f"  ./test-manager.py --addon         # Generate files with EKS addon installation\n"
        f"  ./test-manager.py --addon --version v2.1.1-eksbuild.1  # Generate with specific addon version\n"
        f"  ./test-manager.py generate-files  # Generate files only\n"
        f"  ./test-manager.py create-secrets  # Create secrets only\n"
        f"  ./test-manager.py cleanup-secrets # Cleanup secrets only\n"
        f"  ./test-manager.py cleanup-files   # Cleanup generated files only\n"
        f"  ./test-manager.py validate-image  # Validate ECR image from PRIVREPO env var{RESET}"
    )


if __name__ == "__main__":
    main()
