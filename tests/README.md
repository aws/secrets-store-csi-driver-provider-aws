## Running integration tests

### Quick start

1. `cd` into the `tests/` directory.
2. Run the setup script:

```bash
./setup.sh
```

This will check required tools and create the IAM role for Pod Identity tests.

Subcommands: `./setup.sh deps` (tool check only), `./setup.sh iam` (IAM role only),
`./setup.sh all` (both — default).

3. Run the `export POD_IDENTITY_ROLE_ARN=...` command output by the setup script.
4. Run `./run-tests.sh`

### How it works

The test suite creates real EKS clusters, provisions test secrets in Secrets Manager
and SSM Parameter Store, installs the CSI driver + provider, deploys a test pod, and
verifies that secrets appear as mounted files. The full lifecycle is:

1. **`run-tests.sh`** validates configuration, runs preflight checks, and deploys
   infrastructure for each target (arch × auth type) in parallel via `infra.sh`.
2. **`infra.sh`** creates the cluster using either CloudFormation templates or eksctl
   commands, depending on the `INFRA_BACKEND` setting. Both backends use CloudFormation
   for test secrets and SSM parameters (`cfn/test-resources.yaml`).
3. **`integration.bats`** runs the actual test cases: installs the driver/provider,
   deploys a SecretProviderClass and test pod, then verifies reads, rotation, JMES
   path extraction, K8s Secret sync, cross-region failover, SecureString parameters,
   and error handling for invalid configurations.
4. After tests complete, `run-tests.sh` dumps logs and tears down all infrastructure.

### Architecture

The test suite is designed to work across three environments using pluggable backends:

| Setting | GitHub Actions | Local dev | Ops box |
|---|---|---|---|
| `INFRA_BACKEND` | `eksctl` | `eksctl` or `cfn` | `cfn` |
| `INSTALL_METHOD` | `helm` | `helm` | `addon` |
| `RESOURCE_PREFIX` | _(empty)_ | _(empty)_ | set per environment |
| `PRIVREPO` | ghcr.io build | local ECR | _(unset)_ |

**Infrastructure backends:**

- **`eksctl`** — Creates EKS clusters via eksctl, test secrets/parameters via CloudFormation (`cfn/test-resources.yaml`). Requires `eksctl`.
- **`cfn`** — Creates everything via CloudFormation (`cfn/cluster-stack.yaml` + `cfn/test-resources.yaml`). No eksctl dependency. Best for constrained environments.
- **`auto`** (default) — Uses eksctl if available, otherwise cfn.

**Install methods:**

- **`addon`** — Installs the provider via EKS add-on (includes CSI driver). No `PRIVREPO` needed.
- **`helm`** — Installs the CSI driver via Helm, then the provider via YAML manifest with a custom image. Requires `PRIVREPO`.
- **`yaml`** — Applies the provider YAML manifest only (skips Helm CSI driver install). For environments where the CSI driver is already installed. Requires `PRIVREPO`.
- **`auto`** (default) — Uses helm if `PRIVREPO` is set, otherwise addon.

### Test targets

| Command | What runs |
|---|---|
| `./run-tests.sh` | All 4 test combos in parallel |
| `./run-tests.sh all` | Same as above (explicit) |
| `./run-tests.sh x64` | x64-irsa + x64-pod-identity |
| `./run-tests.sh arm` | arm-irsa + arm-pod-identity |
| `./run-tests.sh irsa` | x64-irsa + arm-irsa |
| `./run-tests.sh pod-identity` | x64-pod-identity + arm-pod-identity |
| `./run-tests.sh x64-irsa` | Single test |

### Flags

- `--version <ver>` — Specify EKS add-on version (only for addon install method)
- `--skip-deploy` — Skip infrastructure deployment (reuse existing clusters)
- `--skip-cleanup` — Skip infrastructure teardown after tests
- `--filter <regex>` — Run only tests matching the regex (passed to `bats --filter`)

### Cleanup

```bash
./run-tests.sh clean              # Clean all clusters/stacks
./run-tests.sh clean x64-irsa     # Clean specific target
./run-tests.sh clean arm          # Clean target group (accepts same shorthands as run)
```

### What happens automatically

Before running tests, `run-tests.sh` performs preflight checks:

- Verifies required tools (conditional on backend/install method)
- Validates AWS credentials (and optional account allowlist via `ALLOWED_ACCOUNTS_FILE`)
- Cleans up stale resources from previous runs
- Detects concurrent test runs (warns if other `integ-cluster-*` stacks exist)
- Warns if `FAILOVERREGION` equals `REGION` (failover tests won't exercise cross-region behavior)
- Checks VPC capacity (each target creates one VPC)

After tests complete, logs are dumped to stdout (for CI) and saved to `tests/logs/<timestamp>/`.

If any test fails, diagnostics (pod status, provider logs, events) are captured in the
log output, and remaining tests in that target are skipped (fail-fast). Other targets
running in parallel are not affected and continue independently.

### Environment variables

| Variable | Required | Description |
|---|---|---|
| `INFRA_BACKEND` | No | `cfn`, `eksctl`, or `auto` (default) |
| `INSTALL_METHOD` | No | `addon`, `helm`, `yaml`, or `auto` (default) |
| `RESOURCE_PREFIX` | No | Prefix for test resource names (collision avoidance) |
| `PRIVREPO` | For helm/yaml | Container image URI for the provider |
| `PRIVTAG` | No | Image tag (appended to PRIVREPO with `:`) |
| `PROVIDER_YAML` | No | Path to provider DaemonSet YAML (default: `../deployment/private-installer.yaml`) |
| `POD_IDENTITY_ROLE_ARN` | For pod-identity | IAM role ARN for Pod Identity |
| `POD_IDENTITY_ROLE_NAME` | No | IAM role name for Pod Identity (default: `pod-identity-role`, used by `setup.sh`) |
| `REGION` | No | Primary AWS region (auto-detected) |
| `FAILOVERREGION` | No | Failover region (auto-detected from same geography) |
| `ADDON_VERSION` | No | EKS add-on version |
| `ALLOWED_ACCOUNTS_FILE` | No | Path to file with allowed AWS account IDs (one per line) |
| `EKS_VERSION` | No | Kubernetes version for EKS cluster (default: `1.35`, CFN backend only) |
| `GHCR_TOKEN` | No | GitHub Container Registry token for pulling test images |

### File structure

```
tests/
├── cfn/
│   ├── cluster-stack.yaml          # VPC + EKS + auth (CFN backend)
│   └── test-resources.yaml         # Test secrets/params, deployed to both regions
├── templates/
│   ├── BasicTestMount.yaml.template    # Test pod spec (envsubst)
│   └── BasicTestMountSPC.yaml.template # SecretProviderClass spec (envsubst)
├── tools/                          # Vendored binaries (bats, kubectl) — gitignored
│   └── .gitkeep
├── infra.sh                        # Pluggable infra backend (cfn or eksctl)
├── integration.bats                # Test cases (bats)
├── helpers.bash                    # bats assertion helpers
├── run-tests.sh                    # Test orchestrator (preflight → deploy → test → cleanup)
├── setup.sh                        # One-time setup (tool check + IAM role)
├── addon_config_values.yaml        # EKS addon config exercising all schema properties
├── resource-names.env              # Canonical test resource names (sourced by infra.sh)
└── README.md
```
