#!/usr/bin/env bats

load helpers

WAIT_TIME=120
SLEEP_TIME=1
PROVIDER_YAML=../deployment/private-installer.yaml
NAMESPACE=kube-system
CLUSTER_NAME=integ-cluster-x64-pod-identity
POD_NAME=basic-test-mount-x64-pod-identity
export REGION=us-west-2
export FAILOVERREGION=us-east-2
export ACCOUNT_NUMBER=$(aws --region $REGION sts get-caller-identity --query Account --output text)

MAGENTA='\033[0;35m'
NC='\033[0m'

log() {
	local msg=$1
	TIMESTAMP=$(date -Iseconds)

	echo -e "${MAGENTA}[$TIMESTAMP] [x64-pod-identity] $msg${NC}" >&3
}

if [[ -z "${PRIVREPO}" ]]; then
	echo "Error: PRIVREPO is not specified" >&2
	return 1
fi

if [[ -z "${NODE_TYPE}" ]]; then
	NODE_TYPE=m5.large
fi

setup_file() {
	log "Starting cluster setup for $CLUSTER_NAME"

	# Create a unique kubeconfig file path for this specific test script
	KUBECONFIG_FILE_X64_POD_IDENTITY=$(mktemp)
	export KUBECONFIG_FILE_X64_POD_IDENTITY
	log "Created Kubeconfig at $KUBECONFIG_FILE_X64_POD_IDENTITY"

	log "Creating EKS cluster with node type $NODE_TYPE"
	eksctl create cluster \
		--name $CLUSTER_NAME \
		--node-type $NODE_TYPE \
		--nodes 3 \
		--region $REGION \
		--kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY

	log "Creating EKS Pod Identity addon"
	eksctl create addon --name eks-pod-identity-agent --cluster $CLUSTER_NAME --region $REGION

	log "Creating IAM role for Pod Identity"
	ROLE_ARN=$(aws --region "$REGION" --query Role.Arn --output text iam create-role --role-name x64-pod-identity-role --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "pods.eks.amazonaws.com"
            },
            "Action": [
                "sts:AssumeRole",
                "sts:TagSession"
            ]
        }
    ]
}')

	log "Attaching policies to Pod Identity role"
	aws iam attach-role-policy \
		--role-name x64-pod-identity-role \
		--policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess

	aws iam attach-role-policy \
		--role-name x64-pod-identity-role \
		--policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite

	log "Creating Pod Identity association"
	eksctl create podidentityassociation \
		--cluster $CLUSTER_NAME \
		--namespace $NAMESPACE \
		--region $REGION \
		--service-account-name basic-test-mount-sa-x64-pod-identity \
		--role-arn $ROLE_ARN \
		--create-service-account true

	log "Adding secrets-store-csi-driver Helm repository"
	helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts

	log "Installing secrets-store-csi-driver via Helm"
	KUBECONFIG=$KUBECONFIG_FILE_X64_POD_IDENTITY helm --namespace=$NAMESPACE install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver --set enableSecretRotation=true --set rotationPollInterval=15s --set syncSecret.enabled=true

	log "Cluster setup completed for $CLUSTER_NAME"
}

teardown_file() {
	log "Starting cluster teardown for $CLUSTER_NAME"

	eksctl delete cluster \
		--name $CLUSTER_NAME \
		--region $REGION

	log "Deleting IAM role: x64-pod-identity-role"
	aws iam detach-role-policy --role-name x64-pod-identity-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess
	aws iam detach-role-policy --role-name x64-pod-identity-role --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite
	aws iam delete-role --role-name x64-pod-identity-role

	log "Cleaning up kubeconfig file"
	rm -f $KUBECONFIG_FILE_X64_POD_IDENTITY

	log "Cluster teardown completed for $CLUSTER_NAME"
}

validate_jmes_mount() {
	log "Validating JMES mount for $USERNAME_ALIAS and $PASSWORD_ALIAS"

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/$USERNAME_ALIAS)
	[[ "${result//$'\r'}" == $USERNAME ]]

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/$PASSWORD_ALIAS)
	[[ "${result//$'\r'}" == $PASSWORD ]]

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/$SECRET_FILE_NAME)
	[[ "${result//$'\r'}" == $SECRET_FILE_CONTENT ]]

	run kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY get secret --namespace $NAMESPACE $K8_SECRET_NAME
	[ "$status" -eq 0 ]

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace=$NAMESPACE get secret $K8_SECRET_NAME -o jsonpath="{.data.username}" | base64 -d)
	[[ "$result" == $USERNAME ]]

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace=$NAMESPACE get secret $K8_SECRET_NAME -o jsonpath="{.data.password}" | base64 -d)
	[[ "$result" == $PASSWORD ]]

	log "JMES mount validation completed successfully"
}

@test "Install aws provider" {
	log "Installing AWS provider"

	envsubst < $PROVIDER_YAML | kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY apply -f -
	cmd="kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE wait --for=condition=Ready --timeout=60s pod -l app=csi-secrets-store-provider-aws"
	wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

	PROVIDER_POD=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE get pod -l app=csi-secrets-store-provider-aws -o jsonpath="{.items[0].metadata.name}")
	run kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE get pod/$PROVIDER_POD
	assert_success

	log "AWS provider installation completed"
}

@test "secretproviderclasses crd is established" {
	log "Verifying secretproviderclasses CRD is established"

	cmd="kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY wait --namespace $NAMESPACE --for condition=established --timeout=60s crd/secretproviderclasses.secrets-store.csi.x-k8s.io"
	wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

	run kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY get crd/secretproviderclasses.secrets-store.csi.x-k8s.io
	assert_success

	log "secretproviderclasses CRD verification completed"
}

@test "deploy aws secretproviderclass crd" {
	log "Deploying AWS SecretProviderClass CRD"

	envsubst < BasicTestMountSPC-x64-PodIdentity.yaml | kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE apply -f -

	cmd="kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE get secretproviderclasses.secrets-store.csi.x-k8s.io/basic-test-mount-spc-x64-pod-identity -o yaml | grep aws"
	wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

	log "AWS SecretProviderClass CRD deployment completed"
}

@test "CSI inline volume test with pod portability" {
	log "Starting CSI inline volume test with pod portability"

	kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE apply -f BasicTestMount-x64-PodIdentity.yaml
	cmd="kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE wait --for=condition=Ready --timeout=60s pod/basic-test-mount-x64-pod-identity"
	wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

	run kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE get pod/$POD_NAME
	assert_success

	log "CSI inline volume test with pod portability completed"
}

@test "CSI inline volume test with rotation - parameter store " {
	log "Starting CSI inline volume test with rotation for Parameter Store"

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParameterStoreRotationTest)
	[[ "${result//$'\r'}" == "BeforeRotation" ]]

	log "Updating Parameter Store value for rotation test"
	aws ssm put-parameter --name ParameterStoreRotationTest --value AfterRotation --type SecureString --overwrite --region $REGION
	sleep 20

	log "Verifying Parameter Store rotation"
	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParameterStoreRotationTest)
	[[ "${result//$'\r'}" == "AfterRotation" ]]

	log "Parameter Store rotation test completed"
}

@test "CSI inline volume test with rotation - secrets manager " {
	log "Starting CSI inline volume test with rotation for Secrets Manager"

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SecretsManagerRotationTest)
	[[ "${result//$'\r'}" == "BeforeRotation" ]]

	log "Updating Secrets Manager value for rotation test"
	aws secretsmanager put-secret-value --secret-id SecretsManagerRotationTest --secret-string AfterRotation --region $REGION
	sleep 20

	log "Verifying Secrets Manager rotation"
	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SecretsManagerRotationTest)
	[[ "${result//$'\r'}" == "AfterRotation" ]]

	log "Secrets Manager rotation test completed"
}

@test "CSI inline volume test with pod portability - read ssm parameters from pod" {
	log "Starting test to read SSM parameters from pod"

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParameterStoreTest1)
	[[ "${result//$'\r'}" == "ParameterStoreTest1Value" ]]

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParameterStoreTest2)
	[[ "${result//$'\r'}" == "ParameterStoreTest2Value" ]]

	log "SSM parameters read test completed"
}

@test "CSI inline volume test with pod portability - read secrets manager secrets from pod" {
	log "Starting test to read Secrets Manager secrets from pod"

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SecretsManagerTest1)
	[[ "${result//$'\r'}" == "SecretsManagerTest1Value" ]]

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SecretsManagerTest2)
	[[ "${result//$'\r'}" == "SecretsManagerTest2Value" ]]

	log "Secrets Manager secrets read test completed"
}

@test "CSI inline volume test with pod portability - specify jmesPath for parameter store parameter with rotation" {
	log "Starting JMES path test for Parameter Store with rotation"

	JSON_CONTENT='{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}'

	USERNAME_ALIAS=ssmUsername USERNAME=ParameterStoreUser PASSWORD_ALIAS=ssmPassword PASSWORD=PasswordForParameterStore\
	SECRET_FILE_NAME=jsonSsm SECRET_FILE_CONTENT=$JSON_CONTENT K8_SECRET_NAME=json-ssm validate_jmes_mount

	log "Updating Parameter Store JSON for JMES path rotation test"
	UPDATED_JSON_CONTENT='{"username": "ParameterStoreUserUpdated", "password": "PasswordForParameterStoreUpdated"}'
	aws ssm put-parameter --name jsonSsm --value "$UPDATED_JSON_CONTENT" --type SecureString --overwrite --region $REGION

	sleep 20
	log "Validating Parameter Store JMES path rotation"
	USERNAME_ALIAS=ssmUsername USERNAME=ParameterStoreUserUpdated PASSWORD_ALIAS=ssmPassword PASSWORD=PasswordForParameterStoreUpdated\
	SECRET_FILE_NAME=jsonSsm SECRET_FILE_CONTENT=$UPDATED_JSON_CONTENT K8_SECRET_NAME=json-ssm validate_jmes_mount

	log "Parameter Store JMES path rotation test completed"
}

@test "CSI inline volume test with pod portability - specify jmesPath for Secrets Manager secret with rotation" {
	log "Starting JMES path test for Secrets Manager with rotation"

	JSON_CONTENT='{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}'

	USERNAME_ALIAS=secretsManagerUsername USERNAME=SecretsManagerUser PASSWORD_ALIAS=secretsManagerPassword \
	PASSWORD=PasswordForSecretsManager SECRET_FILE_NAME=secretsManagerJson SECRET_FILE_CONTENT=$JSON_CONTENT
	K8_SECRET_NAME=secrets-manager-json validate_jmes_mount

	log "Updating Secrets Manager JSON for JMES path rotation test"
	UPDATED_JSON_CONTENT='{"username": "SecretsManagerUserUpdated", "password": "PasswordForSecretsManagerUpdated"}'
	aws secretsmanager put-secret-value --secret-id secretsManagerJson --secret-string "$UPDATED_JSON_CONTENT" --region $REGION

	sleep 20
	log "Validating Secrets Manager JMES path rotation"
	USERNAME_ALIAS=secretsManagerUsername USERNAME=SecretsManagerUserUpdated PASSWORD_ALIAS=secretsManagerPassword \
	PASSWORD=PasswordForSecretsManagerUpdated SECRET_FILE_NAME=secretsManagerJson SECRET_FILE_CONTENT=$UPDATED_JSON_CONTENT
	K8_SECRET_NAME=secrets-manager-json validate_jmes_mount

	log "Secrets Manager JMES path rotation test completed"
}

@test "Sync with Kubernetes Secret" {
	log "Starting Kubernetes Secret sync test"

	run kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY get secret --namespace $NAMESPACE secret
	[ "$status" -eq 0 ]

	result=$(kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace=$NAMESPACE get secret secret -o jsonpath="{.data.username}" | base64 -d)
	[[ "$result" == "SecretUser" ]]

	log "Kubernetes Secret sync test completed"
}

@test "Sync with Kubernetes Secret - Delete deployment. Secret should also be deleted" {
	log "Starting deployment deletion and secret cleanup test"

	run kubectl --kubeconfig=$KUBECONFIG_FILE_X64_POD_IDENTITY --namespace $NAMESPACE delete -f BasicTestMount-x64-PodIdentity.yaml
	assert_success

	log "Waiting for secret to be deleted"
	run wait_for_process $WAIT_TIME $SLEEP_TIME "check_secret_deleted secret $NAMESPACE $KUBECONFIG_FILE_X64_POD_IDENTITY"
	assert_success

	log "Deployment deletion and secret cleanup test completed"
}
