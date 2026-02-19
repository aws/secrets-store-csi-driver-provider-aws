## Running integration tests

1. Build and push a provider image (see [Private Builds](https://github.com/aws/secrets-store-csi-driver-provider-aws/tree/main#private-builds) in the main README). Not required if using `--addon`.
2. `cd` into the `tests/` directory.
3. Run the setup script:

```bash
./setup.sh
```

This will:

- Install [bats](https://github.com/bats-core/bats-core)
- Create a Python virtual environment and install `boto3`
- Create the IAM role for Pod Identity tests with the required managed policies
- Output an `export` command to set `POD_IDENTITY_ROLE_ARN`

You can also run individual setup steps: `./setup.sh deps`, `./setup.sh venv`, or `./setup.sh iam`

4. Run the `export POD_IDENTITY_ROLE_ARN=...` command output by the setup script.
5. Activate the Python virtual environment (if not using system-wide boto3):
   ```bash
   source .venv/bin/activate          # bash/zsh
   overlay use .venv/bin/activate.nu  # nushell
   source .venv/bin/activate.fish     # fish
   ```
   `run-tests.sh` will auto-activate the bash venv as a fallback if boto3 isn't already importable.
6. Ensure that the `PRIVREPO` environment variable is set (not required if using `--addon` flag).
7. Run `./run-tests.sh`

### Test targets

| Command                           | What runs                           |
| --------------------------------- | ----------------------------------- |
| `./run-tests.sh`                  | All 4 test combos in parallel       |
| `./run-tests.sh x64`              | x64-irsa + x64-pod-identity         |
| `./run-tests.sh arm`              | arm-irsa + arm-pod-identity         |
| `./run-tests.sh irsa`             | x64-irsa + arm-irsa                 |
| `./run-tests.sh pod-identity`     | x64-pod-identity + arm-pod-identity |
| `./run-tests.sh x64-irsa`         | Single test                         |
| `./run-tests.sh x64-pod-identity` | Single test                         |
| `./run-tests.sh arm-irsa`         | Single test                         |
| `./run-tests.sh arm-pod-identity` | Single test                         |

### Flags

- `--addon` — Install via EKS add-on instead of Helm (skips `PRIVREPO` requirement)
- `--version <ver>` — Specify EKS add-on version (requires `--addon`)

Examples:

```bash
./run-tests.sh --addon
./run-tests.sh x64-irsa --addon --version v2.1.1-eksbuild.1
```

### Cleanup

```bash
./run-tests.sh clean              # Clean all clusters, stacks, and secrets
./run-tests.sh clean x64-irsa     # Clean specific target
```

### What happens automatically

Before running tests, `run-tests.sh` performs preflight checks:

- Verifies required tools are installed (aws, eksctl, kubectl, bats, helm)
- Validates AWS credentials
- Cleans up stale EKS clusters and orphaned CloudFormation stacks
- Checks VPC capacity (each cluster needs one VPC)

After tests complete, full logs are dumped to stdout (for CI) and saved to `tests/logs/<timestamp>/`.

If any test fails, diagnostics (pod status, describe, logs, events) are captured in the log, and remaining tests are skipped (fail-fast).

### Environment variables

| Variable                | Required                     | Description                                                          |
| ----------------------- | ---------------------------- | -------------------------------------------------------------------- |
| `PRIVREPO`              | Yes (unless `--addon`)       | Container image URI for the provider                                 |
| `PRIVTAG`               | No                           | Image tag (appended to PRIVREPO with `:` separator)                  |
| `POD_IDENTITY_ROLE_ARN` | Yes (for pod-identity tests) | IAM role ARN for Pod Identity                                        |
| `REGION`                | No                           | Primary AWS region (auto-detected)                                   |
| `FAILOVERREGION`        | No                           | Failover region (auto-detected)                                      |
| `NODE_TYPE`             | No                           | EC2 instance type (default: `m5.large` for x64, `m6g.large` for ARM) |
