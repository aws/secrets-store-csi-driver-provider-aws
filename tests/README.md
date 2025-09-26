## Running prow tests

1. Complete the [Private Builds](https://github.com/aws/secrets-store-csi-driver-provider-aws/tree/main#private-builds) section of the README.
2. Install [bats](https://github.com/bats-core/bats-core).
3. If running multi-arch/multi-auth tests, install GNU Parallel (`brew install parallel`).
4. Ensure that the `PRIVREPO` environment variable is set.
5. You can set the `NODE_TYPE_*` environment variables to specify the EC2 instance types used for the test clusters (default: `m5.large` for x64, `m6g.large` for ARM).
6. Create the following two IAM roles:

```bash
export POD_IDENTITY_X64_ROLE_ARN=$(aws --region "$REGION" --query Role.Arn --output text iam create-role --role-name x64-pod-identity-role --assume-role-policy-document '{
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

export POD_IDENTITY_ARM_ROLE_ARN=$(aws --region "$REGION" --query Role.Arn --output text iam create-role --role-name arm-pod-identity-role --assume-role-policy-document '{
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

7. Attach the following policies to each role, replacing `${ARCH}` with `x64` and `arm` respectively:

```bash
aws iam attach-role-policy \
	--role-name ${ARCH}-pod-identity-role \
	--policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess
aws iam attach-role-policy \
	--role-name ${ARCH}-pod-identity-role \
	--policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
```

8. `cd` into the `tests` directory.
9. Run `./run-tests.sh`
   - Running the script without any arguments will run all 4 test cases in parallel (x64 + IRSA, x64 + Pod Identity, ARM + IRSA, ARM + Pod Identity)
   - `./run-tests.sh x64` will run only x64 tests
   - `./run-tests.sh arm` will run only ARM tests
   - `./run-tests.sh x64-irsa` will run only x64 IRSA tests
   - `./run-tests.sh x64-pod-identity` will run only x64 Pod Identity tests
   - `./run-tests.sh arm-irsa` will run only ARM IRSA tests
   - `./run-tests.sh arm-pod-identity` will run only ARM Pod Identity tests
