## Running prow tests

1. Complete the [Private Builds](https://github.com/aws/secrets-store-csi-driver-provider-aws/tree/main#private-builds) section of the README.
2. Install [bats](https://github.com/bats-core/bats-core).
3. If running multi-arch/multi-auth tests, install GNU Parallel (`brew install parallel`).
4. Ensure that the `PRIVREPO` environment variable is set.
5. You can set the `NODE_TYPE_*` environment variables to specify the EC2 instance types used for the test clusters (default: `m5.large` for x64, `m6g.large` for ARM).
6. Create the following two IAM roles:

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

7. Attach the following policies to the role:

```bash
aws iam attach-role-policy \
	--role-name pod-identity-role \
	--policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess
aws iam attach-role-policy \
	--role-name pod-identity-role \
	--policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
```

8. `cd` into the `tests` directory.
9. Create the IAM for the role chaining (`assumeRoleArn`) tests. In the shared CI accounts these are provisioned by infrastructure code; for your own account, run the script once. It creates two fixed-name roles (`ascp-role-chaining-target` and `ascp-role-chaining-untrusted`), the managed policy `ascp-role-chaining-base-policy`, and an inline policy on the Pod Identity role. The script's header documents each one.

```bash
./setup-role-chaining-iam.sh create $POD_IDENTITY_ROLE_ARN
```

   Remove them later with `./setup-role-chaining-iam.sh delete $POD_IDENTITY_ROLE_ARN`.

10. Run `./run-tests.sh`
   - Running the script without any arguments will run all 4 test cases in parallel (x64 + IRSA, x64 + Pod Identity, ARM + IRSA, ARM + Pod Identity)
   - `./run-tests.sh x64` will run only x64 tests
   - `./run-tests.sh arm` will run only ARM tests
   - `./run-tests.sh x64-irsa` will run only x64 IRSA tests
   - `./run-tests.sh x64-pod-identity` will run only x64 Pod Identity tests
   - `./run-tests.sh arm-irsa` will run only ARM IRSA tests
   - `./run-tests.sh arm-pod-identity` will run only ARM Pod Identity tests

## Role chaining tests

Each cell creates a second service account, `assume-role-test-sa-<arch>-<auth>`. For IRSA, `eksctl` gives it a role whose only permission is the `ascp-role-chaining-base-policy` managed policy (`sts:AssumeRole` on the test roles). For Pod Identity it is associated with the same Pod Identity role as the basic tests; the setup script adds an inline policy to that role allowing `sts:AssumeRole` and `sts:TagSession` on the test roles and explicitly denying reads of the `AssumeRole*` objects. A SecretProviderClass with `assumeRoleArn: arn:aws:iam::<account>:role/ascp-role-chaining-target` mounts an `AssumeRole*` secret and parameter into a pod using that service account.

The target role trusts the Pod Identity role with `sts:TagSession` and `aws:PrincipalTag` conditions on the namespace and service account, and the per-run `eksctl` IRSA role by its exact ARN (`eksctl-ascp-role-chaining-base-<arch>-irsa`, a fixed name the tests pass to `eksctl create iamserviceaccount --role-name`). The tests check that:

- the mount succeeds and the files hold the target-role-only objects
- the provider logs the assumed role with the `<namespace>@<serviceAccount>` session name
- rotation keeps working, since every poll assumes the role again
- a target role that does not trust the base role fails the mount: within 120 seconds the pod's `FailedMount` event carries the STS `AccessDenied` with the role ARN rather than the generic "all regions" message, and the pod does not become Ready
