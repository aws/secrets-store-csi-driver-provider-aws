#!/bin/bash

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

	python3 generate-test-files.py
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

cleanup_secrets() {
	echo "Cleaning up secrets and parameters..."
	python3 generate-test-files.py cleanup-secrets
}

# Trap to ensure cleanup happens even if script is interrupted
trap cleanup_generated_files EXIT
trap cleanup_secrets EXIT

# Generate test files from templates (this also creates secrets)
generate_test_files

# Run tests based on argument
if [[ "$1" == "all" || "$1" == "" ]]; then
	check_parallel
	echo "Running all tests: x64-irsa, x64-pod-identity, arm-irsa, arm-pod-identity"
	bats --jobs 4 --no-parallelize-within-files x64-irsa.bats x64-pod-identity.bats arm-irsa.bats arm-pod-identity.bats
fi
if [[ "$1" == "irsa" ]]; then
	check_parallel
	echo "Running IRSA tests: x64-irsa, arm-irsa"
	bats --jobs 2 --no-parallelize-within-files x64-irsa.bats arm-irsa.bats
fi
if [[ "$1" == "pod-identity" ]]; then
	check_parallel
	echo "Running Pod Identity tests: x64-pod-identity, arm-pod-identity"
	bats --jobs 2 --no-parallelize-within-files x64-pod-identity.bats arm-pod-identity.bats
fi
if [[ "$1" == "x64" ]]; then
	check_parallel
	echo "Running x64 tests: x64-irsa, x64-pod-identity"
	bats --jobs 2 --no-parallelize-within-files x64-irsa.bats x64-pod-identity.bats
fi
if [[ "$1" == "arm" ]]; then
	check_parallel
	echo "Running ARM tests: arm-irsa, arm-pod-identity"
	bats --jobs 2 --no-parallelize-within-files arm-irsa.bats arm-pod-identity.bats
fi
if [[ "$1" == "x64-irsa" ]]; then
	echo "Running x64 IRSA test: x64-irsa"
	bats x64-irsa.bats
fi
if [[ "$1" == "x64-pod-identity" ]]; then
	echo "Running x64 Pod Identity test: x64-pod-identity"
	bats x64-pod-identity.bats
fi
if [[ "$1" == "arm-irsa" ]]; then
	echo "Running ARM IRSA test: arm-irsa"
	bats arm-irsa.bats
fi
if [[ "$1" == "arm-pod-identity" ]]; then
	echo "Running ARM Pod Identity test: arm-pod-identity"
	bats arm-pod-identity.bats
fi

cleanup_generated_files
