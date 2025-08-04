#!/bin/bash

REGION=us-west-2
FAILOVERREGION=us-east-2

create_secrets() {
	echo "Creating secrets and parameters"

	# Helper function to create secret if it doesn't exist
	create_secret_if_not_exists() {
		local name=$1
		local value=$2
		local region=$3

		if ! aws secretsmanager describe-secret --secret-id "$name" --region "$region" > /dev/null 2>&1; then
			aws secretsmanager create-secret --name "$name" --secret-string "$value" --region "$region"
		fi
	}

	# Helper function to create parameter if it doesn't exist
	create_parameter_if_not_exists() {
		local name=$1
		local value=$2
		local region=$3

		if ! aws ssm get-parameter --name "$name" --region "$region" > /dev/null 2>&1; then
			aws ssm put-parameter --name "$name" --value "$value" --type SecureString --region "$region"
		fi
	}

	{
		create_secret_if_not_exists "SecretsManagerTest1" "SecretsManagerTest1Value" "$REGION"
		create_secret_if_not_exists "SecretsManagerTest2" "SecretsManagerTest2Value" "$REGION"
		create_secret_if_not_exists "SecretsManagerSync" "SecretUser" "$REGION"
		create_secret_if_not_exists "SecretsManagerTest1" "SecretsManagerTest1Value" "$FAILOVERREGION"
		create_secret_if_not_exists "SecretsManagerTest2" "SecretsManagerTest2Value" "$FAILOVERREGION"
		create_secret_if_not_exists "SecretsManagerSync" "SecretUser" "$FAILOVERREGION"

		create_parameter_if_not_exists "ParameterStoreTest1" "ParameterStoreTest1Value" "$REGION"
		create_parameter_if_not_exists "ParameterStoreTestWithLongName" "ParameterStoreTest2Value" "$REGION"
		create_parameter_if_not_exists "ParameterStoreTest1" "ParameterStoreTest1Value" "$FAILOVERREGION"
		create_parameter_if_not_exists "ParameterStoreTestWithLongName" "ParameterStoreTest2Value" "$FAILOVERREGION"

		create_parameter_if_not_exists "ParameterStoreRotationTest" "BeforeRotation" "$REGION"
		create_secret_if_not_exists "SecretsManagerRotationTest" "BeforeRotation" "$REGION"
		create_parameter_if_not_exists "ParameterStoreRotationTest" "BeforeRotation" "$FAILOVERREGION"
		create_secret_if_not_exists "SecretsManagerRotationTest" "BeforeRotation" "$FAILOVERREGION"

		create_secret_if_not_exists "secretsManagerJson" '{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}' "$REGION"
		create_parameter_if_not_exists "jsonSsm" '{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}' "$REGION"
		create_secret_if_not_exists "secretsManagerJson" '{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}' "$FAILOVERREGION"
		create_parameter_if_not_exists "jsonSsm" '{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}' "$FAILOVERREGION"
	} > /dev/null 2>&1
}

cleanup_secrets() {
	echo "Cleaning up secrets and parameters"

	# Helper function to delete secret if it exists
	delete_secret_if_exists() {
		local name=$1
		local region=$2

		if aws secretsmanager describe-secret --secret-id "$name" --region "$region" > /dev/null 2>&1; then
			aws secretsmanager delete-secret --secret-id "$name" --force-delete-without-recovery --region "$region"
		fi
	}

	# Helper function to delete parameter if it exists
	delete_parameter_if_exists() {
		local name=$1
		local region=$2

		if aws ssm get-parameter --name "$name" --region "$region" > /dev/null 2>&1; then
			aws ssm delete-parameter --name "$name" --region "$region"
		fi
	}

	{
		delete_secret_if_exists "SecretsManagerTest1" "$REGION"
		delete_secret_if_exists "SecretsManagerTest2" "$REGION"
		delete_secret_if_exists "SecretsManagerSync" "$REGION"
		delete_secret_if_exists "SecretsManagerTest1" "$FAILOVERREGION"
		delete_secret_if_exists "SecretsManagerTest2" "$FAILOVERREGION"
		delete_secret_if_exists "SecretsManagerSync" "$FAILOVERREGION"

		delete_parameter_if_exists "ParameterStoreTest1" "$REGION"
		delete_parameter_if_exists "ParameterStoreTestWithLongName" "$REGION"
		delete_parameter_if_exists "ParameterStoreTest1" "$FAILOVERREGION"
		delete_parameter_if_exists "ParameterStoreTestWithLongName" "$FAILOVERREGION"

		delete_parameter_if_exists "ParameterStoreRotationTest" "$REGION"
		delete_secret_if_exists "SecretsManagerRotationTest" "$REGION"
		delete_parameter_if_exists "ParameterStoreRotationTest" "$FAILOVERREGION"
		delete_secret_if_exists "SecretsManagerRotationTest" "$FAILOVERREGION"

		delete_parameter_if_exists "jsonSsm" "$REGION"
		delete_secret_if_exists "secretsManagerJson" "$REGION"
		delete_parameter_if_exists "jsonSsm" "$FAILOVERREGION"
		delete_secret_if_exists "secretsManagerJson" "$FAILOVERREGION"
	} > /dev/null 2>&1
}

check_parallel() {
	if ! command -v parallel >/dev/null 2>&1; then
		echo "GNU parallel not found. Please install: \`brew install parallel\`"
		exit 1
	fi
}

create_secrets

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

cleanup_secrets
