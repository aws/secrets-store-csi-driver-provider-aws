#!/usr/bin/env bats

# Integration tests for AWS Secrets Store CSI Driver Provider.
# Driven entirely by environment variables — no template generation needed.
#
# Required env vars: ARCH, AUTH_TYPE, REGION, FAILOVERREGION
# Optional: USE_ADDON, ADDON_VERSION, PRIVREPO, PRIVTAG, POD_IDENTITY_ROLE_ARN

load helpers

WAIT=30s
WAIT_LONG=120s
PROVIDER_YAML=../deployment/private-installer.yaml
NAMESPACE=kube-system
CLUSTER_NAME="integ-cluster-${ARCH}-${AUTH_TYPE}"
POD_NAME="basic-test-mount-${ARCH}-${AUTH_TYPE}"
SA_NAME="basic-test-mount-sa-${ARCH}-${AUTH_TYPE}"
export ACCOUNT_NUMBER=$(aws --region "$REGION" sts get-caller-identity --query Account --output text)

# --- Helpers ---

case "${ARCH}-${AUTH_TYPE}" in
	x64-irsa)         LOG_COLOR='\033[0;36m' ;;
	x64-pod-identity) LOG_COLOR='\033[0;35m' ;;
	arm-irsa)         LOG_COLOR='\033[0;34m' ;;
	arm-pod-identity) LOG_COLOR='\033[0;33m' ;;
	*)                LOG_COLOR='\033[0m' ;;
esac
NC='\033[0m'

log() { echo -e "${LOG_COLOR}[$(date -Iseconds)] [${ARCH}-${AUTH_TYPE}] $1${NC}" >&3; }

kctl() { kubectl --kubeconfig="$KUBECONFIG_FILE" --namespace "$NAMESPACE" "$@"; }

if [[ "$ARCH" == "arm" ]]; then NODE_TYPE="${NODE_TYPE:-m6g.large}"; else NODE_TYPE="${NODE_TYPE:-m5.large}"; fi

if [[ "$AUTH_TYPE" == "pod-identity" ]]; then
	export POD_IDENTITY_PARAM=$'\n    usePodIdentity: "true"'
else
	export POD_IDENTITY_PARAM=""
fi

export KUBECONFIG_FILE="/tmp/integ-kubeconfig-${ARCH}-${AUTH_TYPE}"
FAIL_MARKER="/tmp/integ-failfast-${ARCH}-${AUTH_TYPE}"

# --- Setup helpers ---

get_partition() { aws sts get-caller-identity --query Arn --output text | cut -d: -f2; }

setup_auth() {
	local partition
	partition=$(get_partition)

	if [[ "$AUTH_TYPE" == "irsa" ]]; then
		log "Associating IAM OIDC provider"
		eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --approve --region "$REGION" >&3 2>&1

		log "Creating IAM service account for IRSA"
		eksctl create iamserviceaccount \
			--name "$SA_NAME" --namespace "$NAMESPACE" --cluster "$CLUSTER_NAME" \
			--attach-policy-arn "arn:${partition}:iam::aws:policy/AmazonSSMReadOnlyAccess" \
			--attach-policy-arn "arn:${partition}:iam::aws:policy/AWSSecretsManagerClientReadOnlyAccess" \
			--override-existing-serviceaccounts --approve --region "$REGION" >&3 2>&1
	else
		log "Creating EKS Pod Identity addon"
		eksctl create addon --name eks-pod-identity-agent --cluster "$CLUSTER_NAME" --region "$REGION" >&3 2>&1

		log "Creating Pod Identity association"
		eksctl create podidentityassociation \
			--cluster "$CLUSTER_NAME" --namespace "$NAMESPACE" --region "$REGION" \
			--service-account-name "$SA_NAME" --role-arn "$POD_IDENTITY_ROLE_ARN" \
			--create-service-account true >&3 2>&1
	fi
}

install_driver() {
	if [[ "$USE_ADDON" == "true" ]]; then
		local version_flag=""
		[[ -n "$ADDON_VERSION" ]] && version_flag="--addon-version $ADDON_VERSION"
		log "Installing via EKS addon"
		aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-secrets-store-csi-driver-provider \
			--configuration-values "file://addon_config_values.yaml" $version_flag --region "$REGION" >&3 2>&1
	else
		log "Installing secrets-store-csi-driver via Helm"
		helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
		KUBECONFIG="$KUBECONFIG_FILE" helm --namespace="$NAMESPACE" install csi-secrets-store \
			secrets-store-csi-driver/secrets-store-csi-driver \
			--set enableSecretRotation=true --set rotationPollInterval=15s --set syncSecret.enabled=true \
			--timeout "$WAIT_LONG" --wait
	fi
}

# --- bats lifecycle ---

setup_file() {
	rm -f "$FAIL_MARKER"
	log "Starting cluster setup for $CLUSTER_NAME"

	eksctl create cluster --name "$CLUSTER_NAME" --node-type "$NODE_TYPE" --nodes 3 \
		--region "$REGION" --kubeconfig="$KUBECONFIG_FILE" >&3 2>&1

	install_driver
	setup_auth

	log "Cluster setup completed"
}

setup() {
	if [[ -f "$FAIL_MARKER" ]]; then skip "Skipped due to earlier failure"; fi
}

teardown() {
	if [[ "$BATS_TEST_COMPLETED" != "1" ]]; then
		touch "$FAIL_MARKER"
		log "FAILED: ${BATS_TEST_DESCRIPTION} — dumping diagnostics"
		echo "# --- pod status ---" >&3
		kctl get pods -o wide 2>&1 | sed 's/^/#   /' >&3 || true
		echo "# --- provider pods ---" >&3
		for pod in $(kctl get pods -l app=csi-secrets-store-provider-aws -o name 2>/dev/null); do
			echo "# describe $pod:" >&3
			kctl describe "$pod" 2>&1 | tail -20 | sed 's/^/#   /' >&3 || true
			echo "# logs $pod:" >&3
			kctl logs "$pod" --tail=20 2>&1 | sed 's/^/#   /' >&3 || true
		done
		echo "# --- test pod ---" >&3
		kctl describe "pod/$POD_NAME" 2>&1 | tail -20 | sed 's/^/#   /' >&3 || true
		echo "# --- events ---" >&3
		kctl get events --sort-by=.lastTimestamp 2>&1 | tail -15 | sed 's/^/#   /' >&3 || true
	fi
}

teardown_file() {
	rm -f "$FAIL_MARKER"
	log "Starting cluster teardown"
	eksctl delete cluster --name "$CLUSTER_NAME" --region "$REGION" >&3 2>&1
	rm -f "$KUBECONFIG_FILE"
	log "Cluster teardown completed"
}

validate_jmes_mount() {
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/$USERNAME_ALIAS")
	[[ "${result//$'\r'}" == "$USERNAME" ]]

	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/$PASSWORD_ALIAS")
	[[ "${result//$'\r'}" == "$PASSWORD" ]]

	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/$SECRET_FILE_NAME")
	[[ "${result//$'\r'}" == "$SECRET_FILE_CONTENT" ]]

	run kctl get secret "$K8_SECRET_NAME"
	[ "$status" -eq 0 ]

	result=$(kctl get secret "$K8_SECRET_NAME" -o jsonpath="{.data.username}" | base64 -d)
	[[ "$result" == "$USERNAME" ]]

	result=$(kctl get secret "$K8_SECRET_NAME" -o jsonpath="{.data.password}" | base64 -d)
	[[ "$result" == "$PASSWORD" ]]
}

# --- Tests ---

@test "Install aws provider" {
	[[ "$USE_ADDON" == "true" ]] && skip "Provider installed via addon"
	log "Installing AWS provider"

	local image="${PRIVREPO}${PRIVTAG:+:${PRIVTAG}}"
	sed "s|\${PRIVREPO}\${PRIVTAG:+:}\${PRIVTAG}|${image}|" "$PROVIDER_YAML" | kctl apply -f -
	kctl wait --for=condition=Ready --timeout="$WAIT_LONG" pod -l app=csi-secrets-store-provider-aws

	run kctl get pod -l app=csi-secrets-store-provider-aws
	assert_success
}

@test "secretproviderclasses crd is established" {
	log "Verifying secretproviderclasses CRD"

	kctl wait --for=condition=established --timeout="$WAIT" crd/secretproviderclasses.secrets-store.csi.x-k8s.io

	run kctl get crd/secretproviderclasses.secrets-store.csi.x-k8s.io
	assert_success
}

@test "deploy aws secretproviderclass crd" {
	log "Deploying SecretProviderClass"

	envsubst < "BasicTestMountSPC.yaml.template" | kctl apply -f -

	run kctl get secretproviderclasses.secrets-store.csi.x-k8s.io/"basic-test-mount-spc-${ARCH}-${AUTH_TYPE}" -o jsonpath='{.spec.provider}'
	[[ "$output" == "aws" ]]
}

@test "CSI inline volume test with pod portability" {
	log "Deploying test pod"

	envsubst < "BasicTestMount.yaml.template" | kctl apply -f -
	kctl wait --for=condition=Ready --timeout="$WAIT_LONG" "pod/$POD_NAME"

	run kctl get pod/"$POD_NAME"
	assert_success
}

@test "CSI inline volume test with rotation - parameter store" {
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/ParameterStoreRotationTest-${ARCH}-${AUTH_TYPE}")
	[[ "${result//$'\r'}" == "BeforeRotation" ]]

	aws ssm put-parameter --name "ParameterStoreRotationTest-${ARCH}-${AUTH_TYPE}" --value AfterRotation --type SecureString --overwrite --region "$REGION"
	sleep 20

	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/ParameterStoreRotationTest-${ARCH}-${AUTH_TYPE}")
	[[ "${result//$'\r'}" == "AfterRotation" ]]
}

@test "CSI inline volume test with rotation - secrets manager" {
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/SecretsManagerRotationTest-${ARCH}-${AUTH_TYPE}")
	[[ "${result//$'\r'}" == "BeforeRotation" ]]

	aws secretsmanager put-secret-value --secret-id "SecretsManagerRotationTest-${ARCH}-${AUTH_TYPE}" --secret-string AfterRotation --region "$REGION"
	sleep 20

	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/SecretsManagerRotationTest-${ARCH}-${AUTH_TYPE}")
	[[ "${result//$'\r'}" == "AfterRotation" ]]
}

@test "read ssm parameters from pod" {
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/ParameterStoreTest1-${ARCH}-${AUTH_TYPE}")
	[[ "${result//$'\r'}" == "ParameterStoreTest1Value" ]]

	result=$(kctl exec "$POD_NAME" -- cat /mnt/secrets-store/ParameterStoreTest2)
	[[ "${result//$'\r'}" == "ParameterStoreTest2Value" ]]
}

@test "read secrets manager secrets from pod" {
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/SecretsManagerTest1-${ARCH}-${AUTH_TYPE}")
	[[ "${result//$'\r'}" == "SecretsManagerTest1Value" ]]

	result=$(kctl exec "$POD_NAME" -- cat /mnt/secrets-store/SecretsManagerTest2)
	[[ "${result//$'\r'}" == "SecretsManagerTest2Value" ]]
}

@test "jmesPath for parameter store with rotation" {
	JSON_CONTENT='{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}'

	USERNAME_ALIAS=ssmUsername USERNAME=ParameterStoreUser PASSWORD_ALIAS=ssmPassword PASSWORD=PasswordForParameterStore \
	SECRET_FILE_NAME="jsonSsm-${ARCH}-${AUTH_TYPE}" SECRET_FILE_CONTENT="$JSON_CONTENT" K8_SECRET_NAME=json-ssm validate_jmes_mount

	UPDATED_JSON_CONTENT='{"username": "ParameterStoreUserUpdated", "password": "PasswordForParameterStoreUpdated"}'
	aws ssm put-parameter --name "jsonSsm-${ARCH}-${AUTH_TYPE}" --value "$UPDATED_JSON_CONTENT" --type SecureString --overwrite --region "$REGION"
	sleep 20

	USERNAME_ALIAS=ssmUsername USERNAME=ParameterStoreUserUpdated PASSWORD_ALIAS=ssmPassword PASSWORD=PasswordForParameterStoreUpdated \
	SECRET_FILE_NAME="jsonSsm-${ARCH}-${AUTH_TYPE}" SECRET_FILE_CONTENT="$UPDATED_JSON_CONTENT" K8_SECRET_NAME=json-ssm validate_jmes_mount
}

@test "jmesPath for secrets manager with rotation" {
	JSON_CONTENT='{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}'

	USERNAME_ALIAS=secretsManagerUsername USERNAME=SecretsManagerUser PASSWORD_ALIAS=secretsManagerPassword \
	PASSWORD=PasswordForSecretsManager SECRET_FILE_NAME="secretsManagerJson-${ARCH}-${AUTH_TYPE}" SECRET_FILE_CONTENT="$JSON_CONTENT" \
	K8_SECRET_NAME=secrets-manager-json validate_jmes_mount

	UPDATED_JSON_CONTENT='{"username": "SecretsManagerUserUpdated", "password": "PasswordForSecretsManagerUpdated"}'
	aws secretsmanager put-secret-value --secret-id "secretsManagerJson-${ARCH}-${AUTH_TYPE}" --secret-string "$UPDATED_JSON_CONTENT" --region "$REGION"
	sleep 20

	USERNAME_ALIAS=secretsManagerUsername USERNAME=SecretsManagerUserUpdated PASSWORD_ALIAS=secretsManagerPassword \
	PASSWORD=PasswordForSecretsManagerUpdated SECRET_FILE_NAME="secretsManagerJson-${ARCH}-${AUTH_TYPE}" SECRET_FILE_CONTENT="$UPDATED_JSON_CONTENT" \
	K8_SECRET_NAME=secrets-manager-json validate_jmes_mount
}

@test "sync with Kubernetes Secret" {
	run kctl get secret secret
	[ "$status" -eq 0 ]

	result=$(kctl get secret secret -o jsonpath="{.data.username}" | base64 -d)
	[[ "$result" == "SecretUser" ]]
}

@test "delete pod - synced secret should also be deleted" {
	run kctl delete pod "$POD_NAME"
	assert_success

	kctl wait --for=delete --timeout="$WAIT" secret/secret
}
