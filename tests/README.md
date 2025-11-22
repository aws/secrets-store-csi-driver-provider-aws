## Running prow tests

1. Complete the [Private Builds](https://github.com/aws/secrets-store-csi-driver-provider-aws/tree/main#private-builds) section of the README.
2. Install [bats](https://github.com/bats-core/bats-core).
3. If running multi-arch/multi-auth tests, install GNU Parallel (`brew install parallel`).
4. `cd` into the `tests/` directory
5. Create a Python virtual environment and install `boto3` and `argparse`. The `run-tests.sh` script will automatically activate the virtual environment. E.g. using `uv`:

```bash
uv venv
uv pip install boto3 argparse
```

6. Ensure that the `PRIVREPO` environment variable is set (not required if using `--addon` flag, see step 9).
7. You can set the `NODE_TYPE_*` environment variables to specify the EC2 instance types used for the test clusters (default: `m5.large` for x64, `m6g.large` for ARM).
8. Create the following IAM role and save it in a shell variable:

```bash
export POD_IDENTITY_ROLE_ARN=$(aws --region "$REGION" --query Role.Arn --output text iam create-role --role-name pod-identity-role --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}')
```

9. Attach the following policies to the role:

```bash
aws iam attach-role-policy \
	--role-name pod-identity-role \
	--policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess
aws iam attach-role-policy \
	--role-name pod-identity-role \
	--policy-arn arn:aws:iam::aws:policy/AWSSecretsManagerClientReadOnlyAccess
```

10. Run `./run-tests.sh`

- Running the script without any arguments will run all 4 test cases in parallel (x64 + IRSA, x64 + Pod Identity, ARM + IRSA, ARM + Pod Identity)
- `./run-tests.sh x64` will run only x64 tests
- `./run-tests.sh arm` will run only ARM tests
- `./run-tests.sh x64-irsa` will run only x64 IRSA tests
- `./run-tests.sh x64-pod-identity` will run only x64 Pod Identity tests
- `./run-tests.sh arm-irsa` will run only ARM IRSA tests
- `./run-tests.sh arm-pod-identity` will run only ARM Pod Identity tests
- Add `--addon` flag to use EKS add-on installation instead of Helm (e.g., `./run-tests.sh --addon` or `./run-tests.sh x64-irsa --addon`)
  - Add `--version` flag to select which EKS add-on version to test. (e.g. `./run-tests.sh pod-identity --addon --version v2.1.1-eksbuild.1`)
