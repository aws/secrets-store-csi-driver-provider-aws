## Running prow tests

1. Complete the [Private Builds](https://github.com/aws/secrets-store-csi-driver-provider-aws/tree/main#private-builds) section of the README.
2. Install [bats](https://github.com/bats-core/bats-core).
3. If running multi-arch/multi-auth tests, install GNU Parallel (`brew install parallel`).
4. Ensure that the `PRIVREPO` environment variable is set.
5. You can set the `NODE_TYPE_*` environment variables to specify the EC2 instance types used for the test clusters (default: `m5.large` for x64, `m6g.large` for ARM).
6. `cd` into the `tests` directory.
7. Run `./run-tests.sh`
   - Running the script without any arguments will run all 4 test cases in parallel (x64 + IRSA, x64 + Pod Identity, ARM + IRSA, ARM + Pod Identity)
   - `./run-tests.sh x64` will run only x64 tests
   - `./run-tests.sh arm` will run only ARM tests
   - `./run-tests.sh x64-irsa` will run only x64 IRSA tests
   - `./run-tests.sh x64-pod-identity` will run only x64 Pod Identity tests
   - `./run-tests.sh arm-irsa` will run only ARM IRSA tests
   - `./run-tests.sh arm-pod-identity` will run only ARM Pod Identity tests
