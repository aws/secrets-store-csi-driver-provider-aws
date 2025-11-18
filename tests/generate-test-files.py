#!/usr/bin/env python3

import os
import sys

import boto3
import botocore.exceptions

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


def aws_operation(client, operation, name, region, exists_code, **kwargs):
    try:
        print(f"  {operation.capitalize()}: {name} in {region}")
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
    eksctl utils associate-iam-oidc-provider --name $CLUSTER_NAME --approve --region $REGION

    log "Creating IAM service account for IRSA"
    eksctl create iamserviceaccount \\
        --name {sa_name} \\
        --namespace $NAMESPACE \\
        --cluster $CLUSTER_NAME \\
        --attach-policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess \\
        --attach-policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite \\
        --override-existing-serviceaccounts \\
        --approve \\
        --region $REGION"""

    return f"""	log "Creating EKS Pod Identity addon"
    eksctl create addon --name eks-pod-identity-agent --cluster $CLUSTER_NAME --region $REGION

    log "Creating Pod Identity association"
    eksctl create podidentityassociation \\
        --cluster $CLUSTER_NAME \\
        --namespace $NAMESPACE \\
        --region $REGION \\
        --service-account-name {sa_name} \\
        --role-arn $POD_IDENTITY_ROLE_ARN \\
        --create-service-account true"""


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
    }

    for old, new in replacements.items():
        content = content.replace(old, new)

    with open(output_file, "w", encoding="utf-8") as f:
        f.write(content)


def get_install_method() -> str:
    use_addon = "--addon" in sys.argv
    if use_addon:
        return """	log "Installing AWS Secrets Store CSI Driver Provider via EKS addon"
	aws eks create-addon --cluster-name $CLUSTER_NAME --addon-name aws-secrets-store-csi-driver-provider --configuration-values \"file://addon_config_values.yaml\" --region $REGION"""

    return """	log "Adding secrets-store-csi-driver Helm repository"
	helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts

	log "Installing secrets-store-csi-driver via Helm"
	KUBECONFIG=${{KUBECONFIG_VAR}} helm --namespace=$NAMESPACE install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver --set enableSecretRotation=true --set rotationPollInterval=15s --set syncSecret.enabled=true"""


def main():
    args = [arg for arg in sys.argv[1:] if not arg.startswith("--")]
    action = args[0] if args else "default"

    if action in ["create-secrets", "cleanup-secrets"]:
        op = "create" if action == "create-secrets" else "cleanup"
        print(
            f"{'Creating' if op == 'create' else 'Cleaning up'} secrets for all test configurations..."
        )
        for config in CONFIGS.values():
            manage_resources(config["ARCH"], config["AUTH_TYPE"], op)
        print(
            f"All secrets {'created' if op == 'create' else 'cleaned up'} successfully"
        )
        return

    if action != "generate-only":
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
        "\nAll test files generated successfully\nUsage:\n"
        "  ./generate-test-files.py                 # Generate files and create secrets\n"
        "  ./generate-test-files.py --addon         # Generate files with EKS addon installation\n"
        "  ./generate-test-files.py generate-only  # Generate files only\n"
        "  ./generate-test-files.py create-secrets # Create secrets only\n"
        "  ./generate-test-files.py cleanup-secrets # Cleanup secrets only"
    )


if __name__ == "__main__":
    main()
