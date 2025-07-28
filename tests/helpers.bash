#!/bin/bash

# Color codes for progress messages
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Progress message function
progress_msg() {
	local color=$1
	local message=$2
	echo -e "${color}${message}${NC}" >&3
}

validate_jmes_mount() {
	local pod_name=$1
	local secret_suffix=$2

	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/$USERNAME_ALIAS)
	[[ "${result//$'\r'}" == $USERNAME ]]

	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/$PASSWORD_ALIAS)
	[[ "${result//$'\r'}" == $PASSWORD ]]

	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/$SECRET_FILE_NAME)
	[[ "${result//$'\r'}" == $SECRET_FILE_CONTENT ]]

	run kubectl get secret --namespace $NAMESPACE $K8_SECRET_NAME$secret_suffix
	[ "$status" -eq 0 ]

	result=$(kubectl --namespace=$NAMESPACE get secret $K8_SECRET_NAME$secret_suffix -o jsonpath="{.data.username}" | base64 -d)
	[[ "$result" == $USERNAME ]]

	result=$(kubectl --namespace=$NAMESPACE get secret $K8_SECRET_NAME$secret_suffix -o jsonpath="{.data.password}" | base64 -d)
	[[ "$result" == $PASSWORD ]]
}

run_test_on_both_clusters_and_auth_methods() {
	local test_function=$1

	progress_msg $CYAN "Running $test_function on x64 cluster with IRSA authentication"
	# Run test on x64 cluster with IRSA
	kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME | head -1)
	$test_function $POD_NAME_IRSA "-irsa"

	progress_msg $CYAN "Running $test_function on x64 cluster with Pod Identity authentication"
	# Run test on x64 cluster with Pod Identity
	kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME | head -1)
	$test_function $POD_NAME_POD_IDENTITY "-pod-identity"

	progress_msg $CYAN "Running $test_function on ARM cluster with IRSA authentication"
	# Run test on ARM cluster with IRSA
	kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME_ARM | head -1)
	$test_function $POD_NAME_IRSA "-irsa"

	progress_msg $CYAN "Running $test_function on ARM cluster with Pod Identity authentication"
	# Run test on ARM cluster with Pod Identity
	kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME_ARM | head -1)
	$test_function $POD_NAME_POD_IDENTITY "-pod-identity"
}

test_rotation_parameter_store() {
	local pod_name=$1
	local secret_suffix=$2

	progress_msg $CYAN "Testing Parameter Store rotation for pod: $pod_name"
	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/ParameterStoreRotationTest)
	[[ "${result//$'\r'}" == "BeforeRotation" ]]

	progress_msg $CYAN "Updating Parameter Store value and waiting for rotation"
	aws ssm put-parameter --name ParameterStoreRotationTest --value AfterRotation --type SecureString --overwrite --region $REGION
	sleep 20
	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/ParameterStoreRotationTest)
	[[ "${result//$'\r'}" == "AfterRotation" ]]
	progress_msg $CYAN "Parameter Store rotation successful for pod: $pod_name"
}

test_rotation_secrets_manager() {
	local pod_name=$1
	local secret_suffix=$2

	progress_msg $CYAN "Testing Secrets Manager rotation for pod: $pod_name"
	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/SecretsManagerRotationTest)
	[[ "${result//$'\r'}" == "BeforeRotation" ]]

	progress_msg $CYAN "Updating Secrets Manager value and waiting for rotation"
	aws secretsmanager put-secret-value --secret-id SecretsManagerRotationTest --secret-string AfterRotation --region $REGION
	sleep 20
	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/SecretsManagerRotationTest)
	[[ "${result//$'\r'}" == "AfterRotation" ]]
	progress_msg $CYAN "Secrets Manager rotation successful for pod: $pod_name"
}

test_read_ssm_parameters() {
	local pod_name=$1
	local secret_suffix=$2

	progress_msg $CYAN "Reading SSM parameters from pod: $pod_name"
	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/ParameterStoreTest1)
	[[ "${result//$'\r'}" == "ParameterStoreTest1Value" ]]

	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/ParameterStoreTest2)
	[[ "${result//$'\r'}" == "ParameterStoreTest2Value" ]]
	progress_msg $CYAN "SSM parameter reading successful for pod: $pod_name"
}

test_read_secrets_manager() {
	local pod_name=$1
	local secret_suffix=$2

	progress_msg $CYAN "Reading Secrets Manager secrets from pod: $pod_name"
	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/SecretsManagerTest1)
	[[ "${result//$'\r'}" == "SecretsManagerTest1Value" ]]

	result=$(kubectl --namespace $NAMESPACE exec $pod_name -- cat /mnt/secrets-store/SecretsManagerTest2)
	[[ "${result//$'\r'}" == "SecretsManagerTest2Value" ]]
	progress_msg $CYAN "Secrets Manager reading successful for pod: $pod_name"
}

test_jmes_parameter_store() {
	local pod_name=$1
	local secret_suffix=$2

	progress_msg $CYAN "Testing JMESPath extraction for Parameter Store from pod: $pod_name"
	JSON_CONTENT='{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}'

	USERNAME_ALIAS=ssmUsername USERNAME=ParameterStoreUser PASSWORD_ALIAS=ssmPassword PASSWORD=PasswordForParameterStore\
	SECRET_FILE_NAME=jsonSsm SECRET_FILE_CONTENT=$JSON_CONTENT K8_SECRET_NAME=json-ssm validate_jmes_mount $pod_name $secret_suffix

	progress_msg $CYAN "Updating Parameter Store JSON and testing rotation"
	UPDATED_JSON_CONTENT='{"username": "ParameterStoreUserUpdated", "password": "PasswordForParameterStoreUpdated"}'
	aws ssm put-parameter --name jsonSsm --value "$UPDATED_JSON_CONTENT" --type SecureString --overwrite --region $REGION

	sleep 20
	USERNAME_ALIAS=ssmUsername USERNAME=ParameterStoreUserUpdated PASSWORD_ALIAS=ssmPassword PASSWORD=PasswordForParameterStoreUpdated\
	SECRET_FILE_NAME=jsonSsm SECRET_FILE_CONTENT=$UPDATED_JSON_CONTENT K8_SECRET_NAME=json-ssm validate_jmes_mount $pod_name $secret_suffix
	progress_msg $CYAN "Parameter Store JMESPath test successful for pod: $pod_name"
}

test_jmes_secrets_manager() {
	local pod_name=$1
	local secret_suffix=$2

	progress_msg $CYAN "Testing JMESPath extraction for Secrets Manager from pod: $pod_name"
	JSON_CONTENT='{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}'

	USERNAME_ALIAS=secretsManagerUsername USERNAME=SecretsManagerUser PASSWORD_ALIAS=secretsManagerPassword \
	PASSWORD=PasswordForSecretsManager SECRET_FILE_NAME=secretsManagerJson SECRET_FILE_CONTENT=$JSON_CONTENT
	K8_SECRET_NAME=secrets-manager-json validate_jmes_mount $pod_name $secret_suffix

	progress_msg $CYAN "Updating Secrets Manager JSON and testing rotation"
	UPDATED_JSON_CONTENT='{"username": "SecretsManagerUserUpdated", "password": "PasswordForSecretsManagerUpdated"}'
	aws secretsmanager put-secret-value --secret-id secretsManagerJson --secret-string "$UPDATED_JSON_CONTENT" --region $REGION

	sleep 20
	USERNAME_ALIAS=secretsManagerUsername USERNAME=SecretsManagerUserUpdated PASSWORD_ALIAS=secretsManagerPassword \
	PASSWORD=PasswordForSecretsManagerUpdated SECRET_FILE_NAME=secretsManagerJson SECRET_FILE_CONTENT=$UPDATED_JSON_CONTENT
	K8_SECRET_NAME=secrets-manager-json validate_jmes_mount $pod_name $secret_suffix
	progress_msg $CYAN "Secrets Manager JMESPath test successful for pod: $pod_name"
}

test_sync_kubernetes_secret() {
	local pod_name=$1
	local secret_suffix=$2

	progress_msg $CYAN "Testing Kubernetes Secret sync for pod: $pod_name"
	run kubectl get secret --namespace $NAMESPACE secret$secret_suffix
	[ "$status" -eq 0 ]

	result=$(kubectl --namespace=$NAMESPACE get secret secret$secret_suffix -o jsonpath="{.data.username}" | base64 -d)
	[[ "$result" == "SecretUser" ]]
	progress_msg $CYAN "Kubernetes Secret sync successful for pod: $pod_name"
}

test_sync_kubernetes_secret_delete() {
	local pod_name=$1
	local secret_suffix=$2
	local auth_method=""

	progress_msg $CYAN "Testing Kubernetes Secret cleanup for pod: $pod_name"
	if [[ "$secret_suffix" == "-irsa" ]]; then
		auth_method="IRSA"
	else
		auth_method="PodIdentity"
	fi

	run kubectl --namespace $NAMESPACE delete -f BasicTestMount-$auth_method.yaml
	assert_success

	run wait_for_process $WAIT_TIME $SLEEP_TIME "check_secret_deleted secret$secret_suffix $NAMESPACE"
	assert_success
	progress_msg $CYAN "Kubernetes Secret cleanup successful for pod: $pod_name"
}

assert_success() {
	if [[ "$status" != 0 ]]; then
		echo "expected: 0"
		echo "actual: $status"
		echo "output: $output"
		return 1
	fi
}

assert_failure() {
	if [[ "$status" == 0 ]]; then
		echo "expected: non-zero exit code"
		echo "actual: $status"
		echo "output: $output"
		return 1
	fi
}

assert_equal() {
	if [[ "$1" != "$2" ]]; then
		echo "expected: $1"
		echo "actual: $2"
		return 1
	fi
}

assert_not_equal() {
	if [[ "$1" == "$2" ]]; then
		echo "unexpected: $1"
		echo "actual: $2"
		return 1
	fi
}

assert_match() {
	if [[ ! "$2" =~ $1 ]]; then
		echo "expected: $1"
		echo "actual: $2"
		return 1
	fi
}

assert_not_match() {
	if [[ "$2" =~ $1 ]]; then
		echo "expected: $1"
		echo "actual: $2"
		return 1
	fi
}

wait_for_process(){
	wait_time="$1"
	sleep_time="$2"
	cmd="$3"
	while [ "$wait_time" -gt 0 ]; do
		if eval "$cmd"; then
			return 0
		else
			sleep "$sleep_time"
			wait_time=$((wait_time-sleep_time))
		fi
	done
	return 1
}

compare_owner_count() {
	secret="$1"
	namespace="$2"
	ownercount="$3"

	[[ "$(kubectl get secret ${secret} -n ${namespace} -o json | jq '.metadata.ownerReferences | length')" -eq $ownercount ]]
}

check_secret_deleted() {
	secret="$1"
	namespace="$2"

	result=$(kubectl get secret -n ${namespace} | grep "^${secret}$" | wc -l)
	[[ "$result" -eq 0 ]]
}
