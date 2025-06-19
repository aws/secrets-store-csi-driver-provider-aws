## Running prow tests

1. Complete the [Private Builds](https://github.com/aws/secrets-store-csi-driver-provider-aws/tree/main#private-builds) section of the README.
2. Install [bats](https://github.com/bats-core/bats-core).
3. Ensure that the `PRIVREPO` environment variable is set.
4. You can set the `NODE_TYPE` environment variable to specify the EC2 instance type used for the test cluster (default: `m5.large`). It is recommended to run the e2e tests using both the default amd64 instance type as well as an arm64 instance type (e.g. `m6g.large`).
5. `cd` into the `tests` directory.
6. Run `bats aws.bats` to run e2e tests.
