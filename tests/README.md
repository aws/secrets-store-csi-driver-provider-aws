## Running prow tests

1. Complete the [Private Builds](https://github.com/aws/secrets-store-csi-driver-provider-aws/tree/main#private-builds) section of the README.
2. `cd` into the `tests/` directory
3. Run the setup script:

```bash
./setup.sh
```

This will:
- Install [bats](https://github.com/bats-core/bats-core) and GNU Parallel (requires `sudo`)
- Create a Python virtual environment and install dependencies (`boto3`, `argparse`)
- Create the IAM role for Pod Identity tests with the required managed policies
- Output an `export` command to set `POD_IDENTITY_ROLE_ARN`

You can also run individual setup steps: `./setup.sh deps`, `./setup.sh venv`, or `./setup.sh iam`

4. Run the `export POD_IDENTITY_ROLE_ARN=...` command output by the setup script.
5. Ensure that the `PRIVREPO` environment variable is set (not required if using `--addon` flag).
6. You can set the `NODE_TYPE_*` environment variables to specify the EC2 instance types used for the test clusters (default: `m5.large` for x64, `m6g.large` for ARM).
7. Run `./run-tests.sh`

- Running the script without any arguments will run all 4 test cases in parallel (x64 + IRSA, x64 + Pod Identity, ARM + IRSA, ARM + Pod Identity)
- `./run-tests.sh x64` will run only x64 tests
- `./run-tests.sh arm` will run only ARM tests
- `./run-tests.sh x64-irsa` will run only x64 IRSA tests
- `./run-tests.sh x64-pod-identity` will run only x64 Pod Identity tests
- `./run-tests.sh arm-irsa` will run only ARM IRSA tests
- `./run-tests.sh arm-pod-identity` will run only ARM Pod Identity tests
- Add `--addon` flag to use EKS add-on installation instead of Helm (e.g., `./run-tests.sh --addon` or `./run-tests.sh x64-irsa --addon`)
  - Add `--version` flag to select which EKS add-on version to test. (e.g. `./run-tests.sh pod-identity --addon --version v2.1.1-eksbuild.1`)
