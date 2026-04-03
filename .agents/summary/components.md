# Components

## Package: `main` (root)

**Files**: `main.go`, `main_test.go`

Entry point for the provider. Bootstraps the gRPC server on a unix socket, initializes the Kubernetes client, and handles graceful shutdown via SIGTERM/SIGINT.

**Key flags**:
| Flag | Default | Purpose |
|------|---------|---------|
| `--provider-volume` | `/var/run/secrets-store-csi-providers` | Unix socket directory |
| `--driver-writes-secrets` | `false` | Whether the CSI driver writes files instead of the provider |
| `--qps` | `5` | K8s API client QPS limit |
| `--burst` | `10` | K8s API client burst limit |
| `--eks-addon-version` | `""` | EKS addon version for User-Agent |
| `--pod-identity-http-timeout` | `""` | HTTP timeout for Pod Identity (Go duration string) |

---

## Package: `server`

**Files**: `server.go`, `server_test.go`

The core orchestrator. Implements the `CSIDriverProviderServer` gRPC interface. Receives mount requests, resolves regions, authenticates, parses descriptors, fetches secrets, and writes files.

**Key types**:
- `CSIDriverProviderServer` — gRPC server struct holding factory, k8s client, and config

**Key functions**:
| Function | Purpose |
|----------|---------|
| `NewServer()` | Factory constructor |
| `Mount()` | Main mount request handler |
| `Version()` | Returns provider version info |
| `getAwsRegions()` | Resolves primary + failover regions |
| `getAwsConfigs()` | Creates AWS configs for each region |
| `getRegionFromNode()` | Falls back to node label or `AWS_REGION` env var |
| `writeFile()` | Atomic file write (temp + rename) |

---

## Package: `auth`

**Files**: `auth.go`, `auth_test.go`

Orchestrates authentication. Creates the appropriate credential provider based on the `usePodIdentity` flag and returns an `aws.Config`.

**Key types**:
- `Auth` — holds region, namespace, service account, pod identity settings, and K8s/STS clients

**Key functions**:
| Function | Purpose |
|----------|---------|
| `NewAuth()` | Creates Auth with STS client (IRSA) or without (Pod Identity) |
| `GetAWSConfig()` | Delegates to the appropriate `ConfigProvider` |
| `getAppID()` | Builds User-Agent string from provider/addon version |

**Constants**: `ProviderName = "secrets-store-csi-driver-provider-aws"`

---

## Package: `credential_provider`

**Files**: `credential_provider.go`, `irsa_credential_provider.go`, `pod_identity_credential_provider.go`, `*_test.go`

Implements two AWS credential acquisition strategies behind the `ConfigProvider` interface.

### IRSACredentialProvider
- Looks up the IAM role ARN from the `eks.amazonaws.com/role-arn` annotation on the K8s service account
- Creates a K8s service account token with audience `sts.amazonaws.com`
- Uses `stscreds.NewWebIdentityRoleProvider` to assume the role via STS

### PodIdentityCredentialProvider
- Creates a K8s service account token with audience `pods.eks.amazonaws.com` bound to the specific pod
- Exchanges the token with the Pod Identity Agent at `169.254.170.23` (IPv4) or `[fd00:ec2::23]` (IPv6)
- Supports configurable address preference (IPv4, IPv6, auto) and HTTP timeout
- Uses `endpointcreds.New` for credential retrieval

---

## Package: `provider`

**Files**: `secret_provider.go`, `secret_descriptor.go`, `secrets_manager_provider.go`, `parameter_store_provider.go`, `secret_value.go`, `*_test.go`

Contains the secret fetching logic and YAML descriptor parsing.

### SecretProviderFactory (`secret_provider.go`)
- Maps `SecretType` → `SecretProvider` implementation
- `ProviderFactoryFactory` function type enables per-request factory creation with region-specific AWS configs

### SecretDescriptor (`secret_descriptor.go`)
- Parses the `objects` YAML from `SecretProviderClass`
- Validates object names, types, ARNs, file permissions, JMESPath entries, and failover objects
- Handles path translation (slash → underscore by default)
- Detects duplicate names/aliases
- Groups descriptors by `SecretType` for batching

### SecretsManagerProvider (`secrets_manager_provider.go`)
- Latency-optimized: uses `DescribeSecret` to check if cached version is current before fetching
- Supports `objectVersion`, `objectVersionLabel`, and failover regions
- Handles both `SecretString` and `SecretBinary` responses

### ParameterStoreProvider (`parameter_store_provider.go`)
- Rate-limit-optimized: batches up to 10 parameters per `GetParameters` call
- Reports invalid parameters as fatal errors
- Supports version and label pinning

### SecretValue (`secret_value.go`)
- Holds fetched secret bytes + descriptor
- `getJsonSecrets()` extracts individual key-value pairs via JMESPath
- `String()` returns `<REDACTED>` to prevent secret leakage in logs

---

## Package: `utils`

**Files**: `error_handling_helper.go`, `error_handling_helper_test.go`

Single utility function `IsFatalError()` that recursively unwraps errors to check if the root cause is a client-side AWS API error (4xx). Used by both providers to distinguish retriable server errors from fatal client errors in the failover logic.

---

## Package: `tests` (integration)

**Files**: `run-tests.sh`, `generate-test-files.py`, `helpers.bash`, `*.bats`, `*.yaml.template`

Integration test suite that runs on real EKS clusters:
- `generate-test-files.py` — creates test secrets/parameters in AWS and generates bats test files from templates
- `run-tests.sh` — orchestrates cluster creation, test execution, and cleanup across 4 configurations (x64/ARM × IRSA/PodIdentity)
- `helpers.bash` — bats assertion helpers
- `integration.bats.template` — parameterized test cases for mount verification

---

## Package: `charts/secrets-store-csi-driver-provider-aws` (Helm)

Helm chart for installing the provider as a DaemonSet. Includes:
- CSI driver as an optional dependency (`secrets-store-csi-driver.install=true` by default)
- RBAC (ServiceAccount, ClusterRole, ClusterRoleBinding)
- Configurable resources, tolerations, node selectors, security context
- FIPS endpoint support (`useFipsEndpoint`)
- K8s API throttling params (`qps`, `burst`)
