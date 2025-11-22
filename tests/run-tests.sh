#!/bin/bash

USE_ADDON=false
ADDON_VERSION=""

cleanup() {
	cleanup_generated_files
	cleanup_secrets
}

check_parallel() {
	if ! command -v parallel >/dev/null 2>&1; then
		echo "GNU parallel not found. Please install: \`brew install parallel\`"
		exit 1
	fi
}

generate_test_files() {
	echo "Generating test files from templates..."
	if [[ ! -f "generate-test-files.py" ]]; then
		echo "Error: generate-test-files.py not found!"
		exit 1
	fi

	ARGS=()
	if [[ "$USE_ADDON" == "true" ]]; then
		ARGS+=(--addon)
	fi
	if [[ -n "$ADDON_VERSION" ]]; then
		ARGS+=(--version "$ADDON_VERSION")
	fi

	python3 generate-test-files.py "${ARGS[@]}"

	if [[ $? -ne 0 ]]; then
		echo "Error: Failed to generate test files from templates"
		exit 1
	fi
	echo "Test files generated successfully"
}

cleanup_generated_files() {
	echo "Cleaning up generated test files..."
	rm -f x64-irsa.bats x64-pod-identity.bats arm-irsa.bats arm-pod-identity.bats
	rm -f BasicTestMountSPC-x64-irsa.yaml BasicTestMountSPC-x64-pod-identity.yaml BasicTestMountSPC-arm-irsa.yaml BasicTestMountSPC-arm-pod-identity.yaml
	rm -f BasicTestMount-x64-irsa.yaml BasicTestMount-x64-pod-identity.yaml BasicTestMount-arm-irsa.yaml BasicTestMount-arm-pod-identity.yaml
	echo "Generated test files cleaned up"
}

delete_cluster() {
	eksctl delete cluster --name $1 --parallel 25
}

cleanup_secrets() {
	echo "Cleaning up secrets and parameters..."
	python3 generate-test-files.py cleanup-secrets
}

# Parse arguments
TEST_TARGET=""
for i in "${!@}"; do
	arg="${!i}"
	if [[ "$arg" == "--addon" ]]; then
		USE_ADDON=true
	elif [[ "$arg" == "--version" ]]; then
		next_i=$((i + 1))
		ADDON_VERSION="${!next_i}"
	elif [[ "$arg" != "--"* ]] && [[ "$arg" != "$ADDON_VERSION" ]]; then
		TEST_TARGET="$arg"
	fi
done

if [[ "$TEST_TARGET" == "clean" ]]; then
	cleanup

	CLEAN_TARGET="${2:-all}"
	if [[ "$CLEAN_TARGET" == "all" || "$CLEAN_TARGET" == "x64" || "$CLEAN_TARGET" == "pod-identity" || "$CLEAN_TARGET" == "x64-pod-identity" ]]; then
		delete_cluster integ-cluster-x64-pod-identity
	fi
	if [[ "$CLEAN_TARGET" == "all" || "$CLEAN_TARGET" == "x64" || "$CLEAN_TARGET" == "irsa" || "$CLEAN_TARGET" == "x64-irsa" ]]; then
		delete_cluster integ-cluster-x64-irsa
	fi
	if [[ "$CLEAN_TARGET" == "all" || "$CLEAN_TARGET" == "arm" || "$CLEAN_TARGET" == "pod-identity" || "$CLEAN_TARGET" == "arm-pod-identity" ]]; then
		delete_cluster integ-cluster-arm-pod-identity
	fi
	if [[ "$CLEAN_TARGET" == "all" || "$CLEAN_TARGET" == "arm" || "$CLEAN_TARGET" == "irsa" || "$CLEAN_TARGET" == "arm-irsa" ]]; then
		delete_cluster integ-cluster-arm-irsa
	fi

	exit $?
fi

# Generate test files from templates (this also creates secrets)
generate_test_files

# Run tests based on argument
if [[ "$TEST_TARGET" == "all" || "$TEST_TARGET" == "" ]]; then
	check_parallel
	echo "Running all tests: x64-irsa, x64-pod-identity, arm-irsa, arm-pod-identity"
	bats --jobs 4 --no-parallelize-within-files x64-irsa.bats x64-pod-identity.bats arm-irsa.bats arm-pod-identity.bats
fi
if [[ "$TEST_TARGET" == "irsa" ]]; then
	check_parallel
	echo "Running IRSA tests: x64-irsa, arm-irsa"
	bats --jobs 2 --no-parallelize-within-files x64-irsa.bats arm-irsa.bats
fi
if [[ "$TEST_TARGET" == "pod-identity" ]]; then
	check_parallel
	echo "Running Pod Identity tests: x64-pod-identity, arm-pod-identity"
	bats --jobs 2 --no-parallelize-within-files x64-pod-identity.bats arm-pod-identity.bats
fi
if [[ "$TEST_TARGET" == "x64" ]]; then
	check_parallel
	echo "Running x64 tests: x64-irsa, x64-pod-identity"
	bats --jobs 2 --no-parallelize-within-files x64-irsa.bats x64-pod-identity.bats
fi
if [[ "$TEST_TARGET" == "arm" ]]; then
	check_parallel
	echo "Running ARM tests: arm-irsa, arm-pod-identity"
	bats --jobs 2 --no-parallelize-within-files arm-irsa.bats arm-pod-identity.bats
fi
if [[ "$TEST_TARGET" == "x64-irsa" ]]; then
	echo "Running x64 IRSA test: x64-irsa"
	bats x64-irsa.bats
fi
if [[ "$TEST_TARGET" == "x64-pod-identity" ]]; then
	echo "Running x64 Pod Identity test: x64-pod-identity"
	bats x64-pod-identity.bats
fi
if [[ "$TEST_TARGET" == "arm-irsa" ]]; then
	echo "Running ARM IRSA test: arm-irsa"
	bats arm-irsa.bats
fi
if [[ "$TEST_TARGET" == "arm-pod-identity" ]]; then
	echo "Running ARM Pod Identity test: arm-pod-identity"
	bats arm-pod-identity.bats
fi

cleanup
