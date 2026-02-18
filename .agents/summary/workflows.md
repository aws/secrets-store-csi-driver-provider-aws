# Workflows

## 1. Mount Request Workflow (Primary)

The main workflow triggered when a pod with a `SecretProviderClass` volume is scheduled.

```mermaid
flowchart TD
    A[CSI Driver sends MountRequest via gRPC] --> B[Unmarshal attributes]
    B --> C{Region specified?}
    C -->|Yes| D[Use specified region]
    C -->|No| E{AWS_REGION env var?}
    E -->|Yes| D2[Use env var region]
    E -->|No| F[Lookup pod → node → region label]
    D --> G[Build region list]
    D2 --> G
    F --> G
    G --> H{failoverRegion specified?}
    H -->|Yes| I[Append failover region]
    H -->|No| J[Single region]
    I --> K[Create AWS configs per region]
    J --> K
    K --> L[Parse SecretDescriptorList from YAML]
    L --> M[Group descriptors by SecretType]
    M --> N[For each type: GetSecretValues]
    N --> O[Write files atomically]
    O --> P[Return MountResponse with versions]
```

## 2. Authentication Workflow

```mermaid
flowchart TD
    A[server.getAwsConfigs] --> B[auth.NewAuth per region]
    B --> C{usePodIdentity?}
    C -->|false / default| D[IRSA Path]
    C -->|true| E[Pod Identity Path]

    D --> D1[K8s: Get ServiceAccount]
    D1 --> D2[Read eks.amazonaws.com/role-arn annotation]
    D2 --> D3[K8s: CreateToken audience=sts.amazonaws.com]
    D3 --> D4[STS: AssumeRoleWithWebIdentity]
    D4 --> D5[Return aws.Config with auto-refreshing creds]

    E --> E1[K8s: CreateToken audience=pods.eks.amazonaws.com bound to pod]
    E1 --> E2{preferredAddressType?}
    E2 -->|auto/ipv4| E3[Try IPv4: 169.254.170.23]
    E2 -->|ipv6| E4[Try IPv6: fd00:ec2::23]
    E3 -->|fail + auto| E4
    E3 -->|success| E5[Return aws.Config]
    E4 -->|success| E5
    E4 -->|fail| E6[Error: failed all endpoints]
```

## 3. Secrets Manager Fetch Workflow

```mermaid
flowchart TD
    A[GetSecretValues] --> B[For each descriptor]
    B --> C[fetchSecretManagerValue]
    C --> D[For each regional client]
    D --> E[fetchSecretManagerValueWithClient]
    E --> F{Secret in curVersionMap?}
    F -->|No - first mount| G[fetchSecret via GetSecretValue]
    F -->|Yes - remount| H[isCurrent via DescribeSecret]
    H --> I{Version current?}
    I -->|Yes| J[reloadSecret from filesystem]
    I -->|No| G
    G --> K[Build SecretValue]
    J --> K
    K --> L{Has JMESPath entries?}
    L -->|Yes| M[Extract JSON sub-values]
    L -->|No| N[Return values]
    M --> N
    D --> O{Error type?}
    O -->|4xx client error| P[Fail immediately]
    O -->|5xx server error| Q[Try next region]
```

## 4. Parameter Store Fetch Workflow

```mermaid
flowchart TD
    A[GetSecretValues] --> B[Batch descriptors in groups of 10]
    B --> C[For each batch]
    C --> D[fetchParameterStoreValue]
    D --> E[For each regional client]
    E --> F[fetchParameterStoreBatch]
    F --> G[Build parameter names with version/label suffixes]
    G --> H[SSM GetParameters with WithDecryption=true]
    H --> I{InvalidParameters?}
    I -->|Yes| J[Return fatal error]
    I -->|No| K[Map results back to descriptors]
    K --> L{Has JMESPath?}
    L -->|Yes| M[Extract JSON sub-values]
    L -->|No| N[Update version map]
    M --> N
    E --> O{Error type?}
    O -->|4xx| P[Fail immediately]
    O -->|5xx| Q[Try next region]
```

## 5. File Write Workflow

```mermaid
flowchart TD
    A[writeFile called per SecretValue] --> B{driverWriteSecrets?}
    B -->|true| C[Return File object to CSI driver]
    B -->|false| D[Create temp file in mount dir]
    D --> E[Set file permissions via Chmod]
    E --> F[Write secret bytes]
    F --> G[Sync to disk]
    G --> H[Rename temp → target path]
    H --> I[Return nil - provider wrote the file]
```

## 6. Build & Release Workflow

```mermaid
flowchart LR
    A[Push to main / PR] --> B[GitHub Actions: go.yml]
    B --> C[gofmt check]
    C --> D[goimports check]
    D --> E[go build]
    E --> F[staticcheck]
    F --> G[go test with coverage]
    G --> H[helm lint]
    H --> I[Codecov upload]

    J[Release] --> K[make all]
    K --> L[docker login to ECR]
    L --> M[docker buildx multi-arch]
    M --> N[Push to public.ecr.aws]
    N --> O[release-chart.yml: publish Helm chart]
```

## 7. Integration Test Workflow

```mermaid
flowchart TD
    A[run-tests.sh] --> B[Create EKS cluster per arch]
    B --> C[generate-test-files.py]
    C --> D[Create test secrets in AWS SM + SSM]
    D --> E[Generate bats files from templates]
    E --> F[Install ASCP via Helm]
    F --> G[Run bats tests]
    G --> H{Parallel mode?}
    H -->|Yes| I[Run x64-irsa, x64-pod-identity, arm-irsa, arm-pod-identity in parallel]
    H -->|No| J[Run specified config]
    I --> K[Cleanup: delete secrets, clusters]
    J --> K
```
