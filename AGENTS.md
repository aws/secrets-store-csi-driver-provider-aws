# AGENTS.md — AI Assistant Guide

> This file provides context for AI coding assistants working on the AWS Secrets Store CSI Driver Provider (ASCP). For user-facing documentation, see [README.md](README.md). For contribution guidelines, see [CONTRIBUTING.md](CONTRIBUTING.md). For detailed architecture documentation, see [.agents/summary/index.md](.agents/summary/index.md).

## Project Overview

ASCP is a Go gRPC server plugin for the [Secrets Store CSI Driver](https://github.com/kubernetes-sigs/secrets-store-csi-driver). It receives mount requests from the CSI driver, authenticates to AWS using the pod's identity (IRSA or EKS Pod Identity), fetches secrets from AWS Secrets Manager or SSM Parameter Store, and writes them as files into the pod's mounted volume.

**Version**: 2.2.1 | **Go**: 1.25 | **Architectures**: linux/amd64, linux/arm64

## Directory Structure

```
.
├── main.go                          # Entry point — gRPC server bootstrap, flag parsing
├── auth/                            # Auth orchestration (IRSA vs Pod Identity selection)
│   └── auth.go                      # NewAuth(), GetAWSConfig() — delegates to credential_provider
├── credential_provider/             # AWS credential acquisition
│   ├── credential_provider.go       # ConfigProvider interface
│   ├── irsa_credential_provider.go  # IRSA: role ARN lookup → STS AssumeRoleWithWebIdentity
│   └── pod_identity_credential_provider.go  # Pod Identity: token → endpoint creds (IPv4/IPv6)
├── provider/                        # Secret fetching and descriptor parsing
│   ├── secret_provider.go           # SecretProvider interface + SecretProviderFactory
│   ├── secret_descriptor.go         # YAML parsing, validation, path translation, dedup
│   ├── secrets_manager_provider.go  # SM: latency-optimized (DescribeSecret → GetSecretValue)
│   ├── parameter_store_provider.go  # SSM: rate-optimized (batch GetParameters, max 10)
│   └── secret_value.go              # SecretValue struct + JMESPath extraction
├── server/                          # gRPC server — mount request handler
│   └── server.go                    # Mount(), writeFile(), region resolution
├── utils/                           # Shared utilities
│   └── error_handling_helper.go     # IsFatalError() — 4xx vs 5xx classification
├── charts/secrets-store-csi-driver-provider-aws/  # Helm chart
├── deployment/                      # kubectl YAML installers
├── examples/                        # Example SecretProviderClass + Deployment YAMLs
├── tests/                           # Integration tests (bats + Python generator)
└── .github/workflows/               # CI: go.yml, integ.yml, docker-image.yml, release-chart.yml
```

## Architecture Quick Reference

```
CSI Driver → gRPC Mount() → resolve region → Auth (IRSA or Pod Identity)
  → SecretDescriptor parsing → Provider (SM or SSM) → write files to pod
```

**Key interfaces**:
- `ConfigProvider` — `GetAWSConfig(ctx)` — implemented by IRSA and Pod Identity providers
- `SecretProvider` — `GetSecretValues(ctx, descriptors, curMap)` — implemented by SM and SSM providers
- `ProviderFactoryFactory` — function type for dependency injection of provider creation

**Failover logic**: On 5xx errors, try the next region. On 4xx errors, fail immediately (`utils.IsFatalError()`).

## Coding Patterns

### Style
- Run `gofmt -s -w .` before committing
- Run `goimports -w ./..` to organize imports
- Run `staticcheck ./...` for static analysis (config in `staticcheck.conf`)
- Use `klog.Infof/Errorf/Warningf` for logging (not `fmt` or `log`)
- Secrets must never appear in logs — `SecretValue.String()` returns `<REDACTED>`

### Error Handling
- AWS API errors: use `utils.IsFatalError()` to distinguish client (4xx, fatal) from server (5xx, retriable)
- Wrap errors with context: `fmt.Errorf("%s: Failed fetching secret %s: %w", region, name, err)`
- Fail fast on validation errors in `SecretDescriptor`

### Testing Patterns
- AWS SDK clients are abstracted behind interfaces (`SecretsManagerGetDescriber`, `ParameterStoreGetter`) for mock injection
- Use `NewSecretsManagerProviderWithClients()` and `NewParameterStoreProviderWithClients()` to inject mock clients
- Server tests use `newServerWithMocks()` to create a fully mocked server
- Test files follow `*_test.go` convention in the same package

### Factory Pattern
- `SecretProviderFactory` maps `SecretType` → `SecretProvider`
- `ProviderFactoryFactory` function type allows the server to create factories with different AWS configs per region
- `NewSecretProviderFactory` is the default implementation

## How to Build and Test

### Build
```bash
go build -v ./...
```

### Unit Tests
```bash
go test -v ./... -coverprofile=coverage.out -covermode=atomic
```

### Lint
```bash
gofmt -s -l .
goimports -d .
staticcheck ./...
```

### Helm Lint
```bash
helm lint charts/*
```

### Docker Build (multi-arch)
```bash
make  # Requires docker login to ECR, builds and pushes linux/amd64 + linux/arm64
```

### Integration Tests
See [tests/README.md](tests/README.md). Requires an EKS cluster, AWS credentials, and `bats`.
```bash
cd tests
./run-tests.sh          # All 4 configs in parallel
./run-tests.sh x64-irsa # Single config
```

## Package-Specific Guidance

### Adding a New Secret Provider
1. Create a new file in `provider/` implementing the `SecretProvider` interface
2. Add a new `SecretType` constant in `secret_descriptor.go`
3. Update the `typeMap` in `secret_descriptor.go`
4. Register the new provider in `NewSecretProviderFactory()` in `secret_provider.go`
5. Add validation rules in `validateSecretDescriptor()` if needed

### Adding a New Credential Provider
1. Create a new file in `credential_provider/` implementing the `ConfigProvider` interface
2. Add a new branch in `auth.GetAWSConfig()` to select the new provider
3. Add any new SecretProviderClass attributes in `server.go` constants

### Modifying SecretDescriptor Validation
- All validation is in `secret_descriptor.go` → `validateSecretDescriptor()` and `validateObjectName()`
- Duplicate detection logic is in `NewSecretDescriptorList()`
- Test coverage is extensive in `secret_descriptor_test.go` (977 LOC, 50+ test functions)

### Modifying the Mount Flow
- Entry point: `server.go` → `Mount()`
- Region resolution: `getAwsRegions()` and `getRegionFromNode()`
- Auth: `getAwsConfigs()` → `auth.NewAuth()` → `auth.GetAWSConfig()`
- File writing: `writeFile()` — atomic via temp file + rename

## Detailed Documentation

For deeper analysis, consult the files in `.agents/summary/`:

| File | Contents |
|------|----------|
| [index.md](.agents/summary/index.md) | Documentation index with cross-reference guide |
| [codebase_info.md](.agents/summary/codebase_info.md) | Tech stack, directory structure, code metrics |
| [architecture.md](.agents/summary/architecture.md) | System design, request flow diagrams, design patterns |
| [components.md](.agents/summary/components.md) | Package-by-package breakdown with functions and types |
| [interfaces.md](.agents/summary/interfaces.md) | All interfaces with signatures and relationship diagram |
| [data_models.md](.agents/summary/data_models.md) | Struct definitions, fields, methods, validation rules |
| [workflows.md](.agents/summary/workflows.md) | Flowcharts for all major processes |
| [dependencies.md](.agents/summary/dependencies.md) | Dependency list, usage map, build tools |
