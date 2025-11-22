#!/bin/bash

REGION="${REGION:-us-west-2}"
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
	if [[ ! -f "test-manager.py" ]]; then
		echo "Error: test-manager.py not found!"
		exit 1
	fi

	source .venv/bin/activate
	python3 test-manager.py cleanup-files

	ARGS=()
	if [[ "$USE_ADDON" == "true" ]]; then
		ARGS+=(--addon)
	fi
	if [[ -n "$ADDON_VERSION" ]]; then
		ARGS+=(--version "$ADDON_VERSION")
	fi

	echo "Generating test files from templates..."
	python3 test-manager.py "${ARGS[@]}"

	if [[ $? -ne 0 ]]; then
		deactivate
		echo "Error: Failed to generate test files from templates"
		exit 1
	fi
	deactivate
	echo "Test files generated successfully"
}

cleanup_generated_files() {
	echo "Cleaning up generated test files..."
	source .venv/bin/activate
	python3 test-manager.py cleanup-files
	deactivate
}

delete_cluster() {
	eksctl delete cluster --name $1 --parallel 25
}

check_and_cleanup_clusters() {
	local targets=("$@")
	local clusters_to_check=()
	
	# Determine which clusters to check based on targets
	for target in "${targets[@]}"; do
		case "$target" in
			""|"all")
				clusters_to_check=("integ-cluster-x64-irsa" "integ-cluster-x64-pod-identity" "integ-cluster-arm-irsa" "integ-cluster-arm-pod-identity")
				break
				;;
			"x64")
				clusters_to_check+=("integ-cluster-x64-irsa" "integ-cluster-x64-pod-identity")
				;;
			"arm")
				clusters_to_check+=("integ-cluster-arm-irsa" "integ-cluster-arm-pod-identity")
				;;
			"irsa")
				clusters_to_check+=("integ-cluster-x64-irsa" "integ-cluster-arm-irsa")
				;;
			"pod-identity")
				clusters_to_check+=("integ-cluster-x64-pod-identity" "integ-cluster-arm-pod-identity")
				;;
			"x64-irsa")
				clusters_to_check+=("integ-cluster-x64-irsa")
				;;
			"x64-pod-identity")
				clusters_to_check+=("integ-cluster-x64-pod-identity")
				;;
			"arm-irsa")
				clusters_to_check+=("integ-cluster-arm-irsa")
				;;
			"arm-pod-identity")
				clusters_to_check+=("integ-cluster-arm-pod-identity")
				;;
		esac
	done
	
	# Check if any clusters exist and delete them
	for cluster in "${clusters_to_check[@]}"; do
		if eksctl get cluster --name "$cluster" --region "$REGION" >/dev/null 2>&1; then
			echo "⚠ Cluster $cluster already exists, deleting..."
			delete_cluster "$cluster"
		fi
	done
}

cleanup_secrets() {
	echo "Cleaning up secrets and parameters..."
	source .venv/bin/activate
	python3 test-manager.py cleanup-secrets
	deactivate
}

# Parse arguments - test target must come before flags
TEST_TARGET=""
if [[ $# -gt 0 ]] && [[ "$1" != "--"* ]]; then
	TEST_TARGET="$1"
	shift
fi

while [[ $# -gt 0 ]]; do
	case "$1" in
		--addon)
			USE_ADDON=true
			shift
			;;
		--version)
			ADDON_VERSION="$2"
			shift 2
			;;
		*)
			echo "Error: Unknown argument '$1' or test target must come before flags"
			exit 1
			;;
	esac
done

if [[ -n "$ADDON_VERSION" ]] && [[ "$USE_ADDON" != "true" ]]; then
	echo "Error: --version flag requires --addon flag"
	exit 1
fi

# Validate POD_IDENTITY_ROLE_ARN for pod-identity targets
if [[ "$TEST_TARGET" == *"pod-identity"* ]] || [[ "$TEST_TARGET" == "" ]] || [[ "$TEST_TARGET" == "all" ]]; then
	if [[ -z "${POD_IDENTITY_ROLE_ARN}" ]]; then
		echo "Error: POD_IDENTITY_ROLE_ARN environment variable is not set (required for pod-identity tests)"
		exit 1
	fi
fi

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

# Validate PRIVREPO image if not using addon
if [[ "$USE_ADDON" != "true" ]]; then
	if [[ -z "${PRIVREPO}" ]]; then
		echo "Error: PRIVREPO environment variable is not set"
		exit 1
	fi
	echo "Validating ECR image: $PRIVREPO"
	source .venv/bin/activate
	python3 test-manager.py validate-image
	if [[ $? -ne 0 ]]; then
		deactivate
		exit 1
	fi
	deactivate
fi

# Check and cleanup any existing clusters for the target
check_and_cleanup_clusters "$TEST_TARGET"

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
