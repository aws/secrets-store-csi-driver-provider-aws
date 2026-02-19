#!/usr/bin/env python3
"""
Test resource manager for AWS Secrets Store CSI Driver integration tests.

Actions:
  create-secrets   Create test secrets/parameters in AWS
  cleanup-secrets  Delete test secrets/parameters from AWS
  validate-image   Validate ECR image from PRIVREPO env var
  print-regions    Print REGION/FAILOVERREGION as shell exports (for eval)
"""

import functools
import os
import re
import sys

import boto3
import botocore.exceptions

SUFFIXES = ["x64-irsa", "x64-pod-identity", "arm-irsa", "arm-pod-identity"]

SECRETS = [
    ("SecretsManagerTest1", "SecretsManagerTest1Value"),
    ("SecretsManagerTest2", "SecretsManagerTest2Value"),
    ("SecretsManagerSync", "SecretUser"),
    ("SecretsManagerRotationTest", "BeforeRotation"),
    (
        "secretsManagerJson",
        '{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}',
    ),
]

PARAMETERS = [
    ("ParameterStoreTest1", "ParameterStoreTest1Value"),
    ("ParameterStoreTestWithLongName", "ParameterStoreTest2Value"),
    ("ParameterStoreRotationTest", "BeforeRotation"),
    (
        "jsonSsm",
        '{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}',
    ),
]


# --- Region detection (lazy) ---


@functools.cache
def get_regions() -> tuple[str, str]:
    """Determine primary and failover region. Cached — only calls AWS once."""
    session = boto3.session.Session()
    region = os.environ.get("REGION") or session.region_name or "us-west-2"

    if os.environ.get("FAILOVERREGION"):
        return region, os.environ["FAILOVERREGION"]

    try:
        ec2 = boto3.client("ec2", region_name=region)
        all_regions = sorted(
            r["RegionName"] for r in ec2.describe_regions(AllRegions=True)["Regions"]
        )
        prefix = region.rsplit("-", 1)[0].rsplit("-", 1)[0]  # "us" from "us-east-1"
        same_geo = [r for r in all_regions if r.startswith(prefix) and r != region]
        failover = (
            same_geo[0]
            if same_geo
            else next((r for r in all_regions if r != region), region)
        )
    except Exception:
        failover = region

    return region, failover


# --- AWS helpers ---


@functools.cache
def get_clients(service: str) -> dict:
    """Cached boto3 clients for both regions."""
    region, failover = get_regions()
    return {r: boto3.client(service, region_name=r) for r in [region, failover]}


def aws_op(
    service: str, operation: str, region: str, ignore_code: str, **kwargs
) -> None:
    """Execute an AWS operation, ignoring a specific error code."""
    client = get_clients(service)[region]
    try:
        getattr(client, operation)(**kwargs)
    except botocore.exceptions.ClientError as e:
        if e.response["Error"]["Code"] == ignore_code:
            return
        raise


def ensure_secret(region: str, name: str, value: str) -> None:
    """Create a secret or reset its value if it already exists or is pending deletion."""
    client = get_clients("secretsmanager")[region]
    try:
        client.create_secret(Name=name, SecretString=value)
        print(f"  + secret {name} ({region})")
    except botocore.exceptions.ClientError as e:
        code = e.response["Error"]["Code"]
        if code == "ResourceExistsException":
            client.put_secret_value(SecretId=name, SecretString=value)
            print(f"  ↻ secret {name} ({region}) [reset]")
        elif code == "InvalidRequestException" and "scheduled for deletion" in str(e):
            client.delete_secret(SecretId=name, ForceDeleteWithoutRecovery=True)
            client.create_secret(Name=name, SecretString=value)
            print(f"  ↻ secret {name} ({region}) [recreated]")
        else:
            raise


# --- Secret/parameter management ---


def manage_secrets(action: str, suffixes: list[str] | None = None) -> None:
    if suffixes is None:
        suffixes = SUFFIXES
    region, failover = get_regions()
    verb = "Creating" if action == "create" else "Cleaning up"
    resource_count = len(suffixes) * 2 * (len(SECRETS) + len(PARAMETERS))
    print(f"{verb} {resource_count} test resources across {region}, {failover}...")

    for suffix in suffixes:
        for r in [region, failover]:
            for base_name, value in SECRETS:
                name = f"{base_name}-{suffix}"
                if action == "create":
                    ensure_secret(r, name, value)
                else:
                    aws_op(
                        "secretsmanager",
                        "delete_secret",
                        r,
                        "ResourceNotFoundException",
                        SecretId=name,
                        ForceDeleteWithoutRecovery=True,
                    )
                    print(f"  - secret {name} ({r})")

            for base_name, value in PARAMETERS:
                name = f"{base_name}-{suffix}"
                if action == "create":
                    aws_op(
                        "ssm",
                        "put_parameter",
                        r,
                        "",
                        Name=name,
                        Value=value,
                        Type="SecureString",
                        Overwrite=True,
                    )
                    print(f"  + parameter {name} ({r})")
                else:
                    aws_op("ssm", "delete_parameter", r, "ParameterNotFound", Name=name)
                    print(f"  - parameter {name} ({r})")

    print(
        f"All resources {'created' if action == 'create' else 'cleaned up'} successfully"
    )


# --- Image validation ---


def validate_image() -> None:
    image_uri = os.environ.get("PRIVREPO")
    if not image_uri:
        print("Error: PRIVREPO environment variable not set")
        sys.exit(1)

    match = re.match(
        r"(\d+)\.dkr\.ecr\.([^.]+)\.amazonaws\.com/([^:]+)(?::(.+))?", image_uri
    )
    if not match:
        print(f"Error: Invalid ECR image URI format: {image_uri}")
        sys.exit(1)

    _, ecr_region, repo, tag = match.groups()
    ecr = boto3.client("ecr", region_name=ecr_region)

    try:
        kwargs = {"repositoryName": repo, "maxResults": 1}
        if tag:
            kwargs["imageIds"] = [{"imageTag": tag}]
        response = ecr.describe_images(**kwargs)
        if not response["imageDetails"]:
            print(f"Error: No images found in repository: {image_uri}")
            sys.exit(1)
        image = response["imageDetails"][0]
        tags = image.get("imageTags", ["<untagged>"])
        display = f"{image_uri}:{tags[0]}" if not tag else image_uri
        print(f"✓ Image validated: {display} (digest: {image['imageDigest']})")
    except botocore.exceptions.ClientError as e:
        print(f"Error validating image: {e}")
        sys.exit(1)


# --- Main ---


def main() -> None:
    if len(sys.argv) < 2:
        print(
            "Usage: test-manager.py <create-secrets|cleanup-secrets|validate-image|print-regions>"
        )
        sys.exit(1)

    action = sys.argv[1]

    if action == "print-regions":
        region, failover = get_regions()
        print(f'export REGION="{region}" FAILOVERREGION="{failover}"')
    elif action in ("create-secrets", "cleanup-secrets"):
        suffixes = sys.argv[2:] or None  # e.g. test-manager.py create-secrets x64-irsa x64-pod-identity
        manage_secrets("create" if "create" in action else "cleanup", suffixes)
    elif action == "validate-image":
        validate_image()
    else:
        print(f"Error: Unknown action '{action}'")
        sys.exit(1)


if __name__ == "__main__":
    main()
