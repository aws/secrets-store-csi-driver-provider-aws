#!/usr/bin/env python3

import os
import sys
from typing import Dict

import boto3
import botocore
import botocore.exceptions

# Configuration for each test variant
CONFIGS = {
    "x64-irsa": {
        "ARCH": "x64",
        "AUTH_TYPE": "irsa",
        "NODE_TYPE_VAR": "NODE_TYPE_X64_IRSA",
        "DEFAULT_NODE_TYPE": "m5.large",
        "KUBECONFIG_VAR": "KUBECONFIG_FILE_X64_IRSA",
        "LOG_COLOR": "CYAN",
        "COLOR_CODE": "36",
    },
    "x64-pod-identity": {
        "ARCH": "x64",
        "AUTH_TYPE": "pod-identity",
        "NODE_TYPE_VAR": "NODE_TYPE_X64_POD_IDENTITY",
        "DEFAULT_NODE_TYPE": "m5.large",
        "KUBECONFIG_VAR": "KUBECONFIG_FILE_X64_POD_IDENTITY",
        "LOG_COLOR": "MAGENTA",
        "COLOR_CODE": "35",
    },
    "arm-irsa": {
        "ARCH": "arm",
        "AUTH_TYPE": "irsa",
        "NODE_TYPE_VAR": "NODE_TYPE_ARM_IRSA",
        "DEFAULT_NODE_TYPE": "m6g.large",
        "KUBECONFIG_VAR": "KUBECONFIG_FILE_ARM_IRSA",
        "LOG_COLOR": "BLUE",
        "COLOR_CODE": "34",
    },
    "arm-pod-identity": {
        "ARCH": "arm",
        "AUTH_TYPE": "pod-identity",
        "NODE_TYPE_VAR": "NODE_TYPE_ARM_POD_IDENTITY",
        "DEFAULT_NODE_TYPE": "m6g.large",
        "KUBECONFIG_VAR": "KUBECONFIG_FILE_ARM_POD_IDENTITY",
        "LOG_COLOR": "YELLOW",
        "COLOR_CODE": "33",
    },
}

REGION = os.environ.get("REGION", "us-west-2")
FAILOVERREGION = os.environ.get("FAILOVERREGION", "us-east-2")

secretsmanager = {
    REGION: boto3.client("secretsmanager", region_name=REGION),
    FAILOVERREGION: boto3.client("secretsmanager", region_name=FAILOVERREGION),
}
ssm = {
    REGION: boto3.client("ssm", region_name=REGION),
    FAILOVERREGION: boto3.client("ssm", region_name=FAILOVERREGION),
}


def create_secret_if_not_exists(name: str, value: str, region: str):
    """Create secret if it doesn't exist"""
    try:
        print(f"  Creating secret: {name} in {region}")
        secretsmanager[region].create_secret(Name=name, SecretString=value)
    except botocore.exceptions.ClientError as error:
        if error.response["Error"]["Code"] == "ResourceExistsException":
            print(f"  Secret already exists: {name} in {region}")
        else:
            raise error


def create_parameter_if_not_exists(name: str, value: str, region: str):
    """Create parameter if it doesn't exist"""
    try:
        print(f"  Creating parameter: {name} in {region}")
        ssm[region].put_parameter(
            Name=name, Value=value, Type="SecureString", Overwrite=False
        )
    except botocore.exceptions.ClientError as error:
        if error.response["Error"]["Code"] == "ParameterAlreadyExists":
            print(f"  Parameter already exists: {name} in {region}")
        else:
            raise error


def delete_secret_if_exists(name: str, region: str):
    """Delete secret if it exists"""
    print(f"  Deleting secret: {name} in {region}")
    secretsmanager[region].delete_secret(SecretId=name, ForceDeleteWithoutRecovery=True)


def delete_parameter_if_exists(name: str, region: str):
    """Delete parameter if it exists"""
    print(f"  Deleting parameter: {name} in {region}")
    try:
        ssm[region].delete_parameter(Name=name)
    except botocore.exceptions.ClientError as error:
        if error.response["Error"]["Code"] == "ParameterNotFound":
            print(f"  Parameter does not exist: {name} in {region}")
        else:
            raise error


def create_secrets_for_config(arch: str, auth_type: str):
    """Create secrets for a specific test configuration"""
    suffix = f"{arch}-{auth_type}"
    print(f"Creating secrets and parameters for {suffix}...")

    # Create secrets in primary region
    create_secret_if_not_exists(
        f"SecretsManagerTest1-{suffix}", "SecretsManagerTest1Value", REGION
    )
    create_secret_if_not_exists(
        f"SecretsManagerTest2-{suffix}", "SecretsManagerTest2Value", REGION
    )
    create_secret_if_not_exists(f"SecretsManagerSync-{suffix}", "SecretUser", REGION)
    create_secret_if_not_exists(
        f"SecretsManagerRotationTest-{suffix}", "BeforeRotation", REGION
    )
    create_secret_if_not_exists(
        f"secretsManagerJson-{suffix}",
        '{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}',
        REGION,
    )

    # Create secrets in failover region
    create_secret_if_not_exists(
        f"SecretsManagerTest1-{suffix}", "SecretsManagerTest1Value", FAILOVERREGION
    )
    create_secret_if_not_exists(
        f"SecretsManagerTest2-{suffix}", "SecretsManagerTest2Value", FAILOVERREGION
    )
    create_secret_if_not_exists(
        f"SecretsManagerSync-{suffix}", "SecretUser", FAILOVERREGION
    )
    create_secret_if_not_exists(
        f"SecretsManagerRotationTest-{suffix}", "BeforeRotation", FAILOVERREGION
    )
    create_secret_if_not_exists(
        f"secretsManagerJson-{suffix}",
        '{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}',
        FAILOVERREGION,
    )

    # Create parameters in primary region
    create_parameter_if_not_exists(
        f"ParameterStoreTest1-{suffix}", "ParameterStoreTest1Value", REGION
    )
    create_parameter_if_not_exists(
        f"ParameterStoreTestWithLongName-{suffix}", "ParameterStoreTest2Value", REGION
    )
    create_parameter_if_not_exists(
        f"ParameterStoreRotationTest-{suffix}", "BeforeRotation", REGION
    )
    create_parameter_if_not_exists(
        f"jsonSsm-{suffix}",
        '{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}',
        REGION,
    )

    # Create parameters in failover region
    create_parameter_if_not_exists(
        f"ParameterStoreTest1-{suffix}", "ParameterStoreTest1Value", FAILOVERREGION
    )
    create_parameter_if_not_exists(
        f"ParameterStoreTestWithLongName-{suffix}",
        "ParameterStoreTest2Value",
        FAILOVERREGION,
    )
    create_parameter_if_not_exists(
        f"ParameterStoreRotationTest-{suffix}", "BeforeRotation", FAILOVERREGION
    )
    create_parameter_if_not_exists(
        f"jsonSsm-{suffix}",
        '{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}',
        FAILOVERREGION,
    )


def cleanup_secrets_for_config(arch: str, auth_type: str):
    """Cleanup secrets for a specific test configuration"""
    suffix = f"{arch}-{auth_type}"
    print(f"Cleaning up secrets and parameters for {suffix}...")

    # Delete secrets from primary region
    delete_secret_if_exists(f"SecretsManagerTest1-{suffix}", REGION)
    delete_secret_if_exists(f"SecretsManagerTest2-{suffix}", REGION)
    delete_secret_if_exists(f"SecretsManagerSync-{suffix}", REGION)
    delete_secret_if_exists(f"SecretsManagerRotationTest-{suffix}", REGION)
    delete_secret_if_exists(f"secretsManagerJson-{suffix}", REGION)

    # Delete secrets from failover region
    delete_secret_if_exists(f"SecretsManagerTest1-{suffix}", FAILOVERREGION)
    delete_secret_if_exists(f"SecretsManagerTest2-{suffix}", FAILOVERREGION)
    delete_secret_if_exists(f"SecretsManagerSync-{suffix}", FAILOVERREGION)
    delete_secret_if_exists(f"SecretsManagerRotationTest-{suffix}", FAILOVERREGION)
    delete_secret_if_exists(f"secretsManagerJson-{suffix}", FAILOVERREGION)

    # Delete parameters from primary region
    delete_parameter_if_exists(f"ParameterStoreTest1-{suffix}", REGION)
    delete_parameter_if_exists(f"ParameterStoreTestWithLongName-{suffix}", REGION)
    delete_parameter_if_exists(f"ParameterStoreRotationTest-{suffix}", REGION)
    delete_parameter_if_exists(f"jsonSsm-{suffix}", REGION)

    # Delete parameters from failover region
    delete_parameter_if_exists(f"ParameterStoreTest1-{suffix}", FAILOVERREGION)
    delete_parameter_if_exists(
        f"ParameterStoreTestWithLongName-{suffix}", FAILOVERREGION
    )
    delete_parameter_if_exists(f"ParameterStoreRotationTest-{suffix}", FAILOVERREGION)
    delete_parameter_if_exists(f"jsonSsm-{suffix}", FAILOVERREGION)


def get_auth_setup(arch: str, auth_type: str) -> str:
    """Generate authentication setup code"""
    if auth_type == "irsa":
        return f"""	log "Associating IAM OIDC provider"
    eksctl utils associate-iam-oidc-provider --name $CLUSTER_NAME --approve --region $REGION

    log "Creating IAM service account for IRSA"
    eksctl create iamserviceaccount \\
        --name basic-test-mount-sa-{arch}-{auth_type} \\
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
        --service-account-name basic-test-mount-sa-{arch}-{auth_type} \\
        --role-arn $POD_IDENTITY_ROLE_ARN \\
        --create-service-account true"""


def get_pod_identity_param(auth_type: str) -> str:
    """Generate Pod Identity parameter"""
    if auth_type == "pod-identity":
        return '\n    usePodIdentity: "true"'

    return ""


def replace_template_vars(template_file: str, output_file: str, config: Dict[str, str]):
    """Replace template variables in a file"""
    with open(template_file, "r", encoding="utf-8") as f:
        content = f.read()

    # Replace simple variables
    for key, value in config.items():
        content = content.replace(f"{{{{{key}}}}}", value)

    # Replace multi-line variables
    arch = config["ARCH"]
    auth_type = config["AUTH_TYPE"]

    content = content.replace("{{AUTH_SETUP}}", get_auth_setup(arch, auth_type))
    content = content.replace(
        "{{POD_IDENTITY_PARAM}}", get_pod_identity_param(auth_type)
    )

    with open(output_file, "w", encoding="utf-8") as f:
        f.write(content)


def main():
    """Main function"""
    # Parse command line arguments
    if len(sys.argv) > 1:
        action = sys.argv[1]
    else:
        action = "default"

    if action == "create-secrets":
        print("Creating secrets for all test configurations...")
        for config_name, config in CONFIGS.items():
            create_secrets_for_config(config["ARCH"], config["AUTH_TYPE"])
        print("All secrets created successfully")
        return
    if action == "cleanup-secrets":
        print("Cleaning up secrets for all test configurations...")
        for config_name, config in CONFIGS.items():
            cleanup_secrets_for_config(config["ARCH"], config["AUTH_TYPE"])
        print("All secrets cleaned up successfully")
        return
    if action == "generate-only":
        # Just generate files, don't manage secrets
        pass
    else:
        # Default behavior: generate files and create secrets
        print("Creating secrets for all test configurations...")
        for config_name, config in CONFIGS.items():
            create_secrets_for_config(config["ARCH"], config["AUTH_TYPE"])

    # Generate files for each configuration
    for config_name, config in CONFIGS.items():
        print(f"Generating files for {config_name}...")

        arch = config["ARCH"]
        auth_type = config["AUTH_TYPE"]

        # Generate BATS file
        replace_template_vars(
            "integration.bats.template", f"{config_name}.bats", config
        )

        # Generate SecretProviderClass file
        replace_template_vars(
            "BasicTestMountSPC.yaml.template",
            f"BasicTestMountSPC-{arch}-{auth_type}.yaml",
            config,
        )

        # Generate Pod deployment file
        replace_template_vars(
            "BasicTestMount.yaml.template",
            f"BasicTestMount-{arch}-{auth_type}.yaml",
            config,
        )

        print(f"  Generated: {config_name}.bats")
        print(f"  Generated: BasicTestMountSPC-{arch}-{auth_type}.yaml")
        print(f"  Generated: BasicTestMount-{arch}-{auth_type}.yaml")

    print("\nAll test files generated successfully")
    print("\nGenerated files:")
    for config_name, _ in CONFIGS.items():
        print(f"  - {config_name}.bats")
    for config_name, config in CONFIGS.items():
        arch = config["ARCH"]
        auth_type = config["AUTH_TYPE"]
        print(f"  - BasicTestMountSPC-{arch}-{auth_type}.yaml")
        print(f"  - BasicTestMount-{arch}-{auth_type}.yaml")

    print("\nUsage:")
    print(
        "  ./generate-test-files.py                 # Generate files and create secrets"
    )
    print("  ./generate-test-files.py generate-only  # Generate files only")
    print("  ./generate-test-files.py create-secrets # Create secrets only")
    print("  ./generate-test-files.py cleanup-secrets # Cleanup secrets only")


if __name__ == "__main__":
    main()
