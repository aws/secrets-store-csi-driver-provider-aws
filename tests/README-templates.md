# Templated Test System

This directory contains a templated test system that eliminates the need to maintain 4 separate sets of test files for each combination of architecture (x64/ARM) and authentication type (IRSA/Pod Identity).

## Overview

Instead of maintaining 12 separate files (4 BATS files + 4 SecretProviderClass files + 4 deployment files), we now have:

- **3 template files** that generate all the test files
- **1 generation script** that creates the 4 sets of files from templates
- **1 enhanced test runner** that manages the entire process

## Files

### Template Files
- `integration.bats.template` - BATS test template
- `BasicTestMountSPC.yaml.template` - SecretProviderClass template  
- `BasicTestMount.yaml.template` - Pod deployment template

### Scripts
- `generate-test-files.py` - Python script that generates test files from templates and manages secrets
- `run-tests-new.sh` - Enhanced test runner that uses the template system

### Generated Files (created automatically)
- `x64-irsa.bats`, `x64-pod-identity.bats`, `arm-irsa.bats`, `arm-pod-identity.bats`
- `BasicTestMountSPC-{arch}-{auth}.yaml` files
- `BasicTestMount-{arch}-{auth}.yaml` files

## Key Improvements

### 1. Unique Secrets Per Test Configuration
Each test configuration now uses its own set of secrets and parameters with suffixes like `-x64-irsa`, `-arm-pod-identity`, etc. This provides complete isolation between parallel test runs.

### 2. Integrated Secret Management
The generation script handles creating and cleaning up secrets for each test configuration, eliminating the shared secret management from the main test runner.

### 3. Template-Based Generation
All differences between test configurations are parameterized in templates:
- Architecture-specific node types (m5.large vs m6g.large)
- Authentication setup (IRSA vs Pod Identity)
- Unique naming for clusters, pods, service accounts, and secrets
- Color-coded logging for each test variant

## Usage

### Basic Usage
```bash
# Generate files and run all tests
./run-tests-new.sh

# Run specific test combinations
./run-tests-new.sh irsa          # x64-irsa + arm-irsa
./run-tests-new.sh pod-identity  # x64-pod-identity + arm-pod-identity
./run-tests-new.sh x64           # x64-irsa + x64-pod-identity
./run-tests-new.sh arm           # arm-irsa + arm-pod-identity

# Run individual tests
./run-tests-new.sh x64-irsa
./run-tests-new.sh arm-pod-identity
```

### Manual Secret Management
```bash
# Generate files and create secrets
./generate-test-files.py

# Generate files only (no secret management)
./generate-test-files.py generate-only

# Create secrets only
./generate-test-files.py create-secrets

# Cleanup secrets only
./generate-test-files.py cleanup-secrets
```

## Template Variables

The templates use the following variables:

- `{{ARCH}}` - Architecture: `x64` or `arm`
- `{{AUTH_TYPE}}` - Authentication: `irsa` or `pod-identity`
- `{{NODE_TYPE_VAR}}` - Environment variable name for node type
- `{{DEFAULT_NODE_TYPE}}` - Default EC2 instance type
- `{{KUBECONFIG_VAR}}` - Environment variable name for kubeconfig file
- `{{LOG_COLOR}}` - Color name for logging
- `{{COLOR_CODE}}` - ANSI color code
- `{{AUTH_SETUP}}` - Authentication-specific setup commands
- `{{TEARDOWN_CLEANUP}}` - Authentication-specific cleanup commands
- `{{POD_IDENTITY_PARAM}}` - Pod Identity parameter for SPC

## Secret Naming Convention

Each test configuration uses uniquely named secrets and parameters:

- `SecretsManagerTest1-{arch}-{auth}`
- `ParameterStoreTest1-{arch}-{auth}`
- `jsonSsm-{arch}-{auth}`
- etc.

This ensures complete isolation between test runs and enables safe parallel execution.

## Migration from Old System

The old individual test files are no longer needed and can be removed:
- `x64-irsa.bats`, `arm-irsa.bats`, `x64-pod-identity.bats`, `arm-pod-identity.bats`
- `BasicTestMountSPC-*.yaml` files
- `BasicTestMount-*.yaml` files

The original `run-tests.sh` can be replaced with `run-tests-new.sh`.

## Benefits

1. **Reduced Maintenance**: Only 3 template files to maintain instead of 12 individual files
2. **Consistency**: All test variants are guaranteed to be consistent since they're generated from the same templates
3. **Isolation**: Each test uses its own secrets, preventing conflicts
4. **Flexibility**: Easy to add new test variants or modify existing ones
5. **Parallel Execution**: Maintains the ability to run tests in parallel with complete isolation
