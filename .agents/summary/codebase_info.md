# Codebase Information

## Project

- **Name**: AWS Secrets Manager and Config Provider for Secret Store CSI Driver (ASCP)
- **Repository**: `github.com/aws/secrets-store-csi-driver-provider-aws`
- **Version**: 2.2.1
- **License**: Apache-2.0

## Tech Stack

| Category | Technology | Version |
|----------|-----------|---------|
| Language | Go | 1.25 |
| AWS SDK | aws-sdk-go-v2 | 1.41.1 |
| RPC | gRPC | 1.78.0 |
| Kubernetes | client-go | 0.35.0 |
| CSI Driver | secrets-store-csi-driver | 1.5.5 |
| Container Base | scratch + Amazon Linux 2 (certs only) | — |
| Package Manager | Helm | Chart v2.2.1 |
| CI | GitHub Actions | — |

## Build & Deployment

- **Build**: Multi-stage Docker build (golang:1.25-alpine → scratch)
- **Architectures**: linux/amd64, linux/arm64
- **Registry**: `public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws`
- **Kubernetes Deployment**: DaemonSet in `kube-system` namespace
- **Minimum EKS Version**: 1.17 (1.24+ for Pod Identity)

## Directory Structure

```
.
├── main.go                          # Entry point — gRPC server bootstrap
├── main_test.go                     # Flag parsing tests
├── go.mod / go.sum                  # Go module dependencies
├── Makefile                         # Docker build, push, and tagging
├── Dockerfile                       # Multi-stage build (scratch final image)
├── auth/                            # Auth orchestration (IRSA vs Pod Identity)
│   ├── auth.go
│   └── auth_test.go
├── credential_provider/             # AWS credential acquisition
│   ├── credential_provider.go       # ConfigProvider interface
│   ├── irsa_credential_provider.go  # IRSA implementation
│   ├── pod_identity_credential_provider.go  # Pod Identity implementation
│   └── *_test.go
├── provider/                        # Secret fetching and descriptor parsing
│   ├── secret_provider.go           # SecretProvider interface + factory
│   ├── secret_descriptor.go         # YAML parsing, validation, path handling
│   ├── secrets_manager_provider.go  # Secrets Manager implementation
│   ├── parameter_store_provider.go  # SSM Parameter Store implementation
│   ├── secret_value.go              # SecretValue + JMESPath extraction
│   └── *_test.go
├── server/                          # gRPC server — mount request handler
│   ├── server.go
│   └── server_test.go
├── utils/                           # Shared utilities
│   ├── error_handling_helper.go     # Fatal error detection (4xx vs 5xx)
│   └── error_handling_helper_test.go
├── charts/                          # Helm chart
│   └── secrets-store-csi-driver-provider-aws/
├── deployment/                      # kubectl YAML installers
│   ├── aws-provider-installer.yaml
│   └── private-installer.yaml
├── examples/                        # Example SecretProviderClass + Deployment YAMLs
├── tests/                           # Integration tests (bats + Python generator)
└── .github/workflows/               # CI: go.yml, integ.yml, docker-image.yml, release-chart.yml
```

## Code Metrics

| Package | Files | LOC (source) | LOC (tests) |
|---------|-------|-------------|-------------|
| root (main) | 2 | 119 | 141 |
| server | 2 | 359 | 2,857 |
| provider | 5 | 1,096 | 1,049 |
| auth | 2 | 113 | 221 |
| credential_provider | 3 | 287 | 744 |
| utils | 2 | 21 | 50 |
| tests (integration) | 3 | 557 | — |
| **Total** | **19** | **~2,552** | **~5,062** |

Test-to-source ratio is approximately 2:1, indicating strong test coverage.
