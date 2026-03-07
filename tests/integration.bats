#!/usr/bin/env bats

# Integration tests for AWS Secrets Store CSI Driver Provider.
#
# These tests verify that secrets from Secrets Manager and parameters from
# SSM Parameter Store can be mounted into pods via the CSI driver. Tests cover:
#   - Basic secret/parameter reads
#   - Secret rotation (value changes reflected after CSI driver rotation interval)
#   - JMES path extraction (mounting individual JSON keys as separate files)
#   - Kubernetes Secret sync (CSI driver syncs mounted secrets to K8s Secrets)
#   - Cross-region failover (secrets fetched from failover region on primary failure)
#
# Required env vars: ARCH, AUTH_TYPE, REGION, FAILOVERREGION
# Optional: INSTALL_METHOD, INFRA_BACKEND, RESOURCE_PREFIX, ADDON_VERSION,
#           PRIVREPO, PRIVTAG, POD_IDENTITY_ROLE_ARN, GHCR_TOKEN

load helpers

# ============================================================
# Configuration
# ============================================================

BATS_TEST_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
export PATH="${PATH}:${BATS_TEST_DIR}/tools/bats/bin:${BATS_TEST_DIR}/tools:${APOLLO_ENVIRONMENT_ROOT:-}/bin"

WAIT=30s
WAIT_LONG=300s
export BUSYBOX_IMAGE="public.ecr.aws/docker/library/busybox:1.36"
# Path to the provider DaemonSet YAML, used by the helm/yaml install method.
# Defaults to the location within the OSS repo; override via env var when
# running from a different directory.
PROVIDER_YAML="${PROVIDER_YAML:-../deployment/private-installer.yaml}"
NAMESPACE=kube-system

# Naming convention: all test resources include ARCH and AUTH_TYPE to allow
# parallel test runs in the same account without collisions.
CLUSTER_NAME="integ-cluster-${ARCH}-${AUTH_TYPE}"
POD_NAME="basic-test-mount-${ARCH}-${AUTH_TYPE}"
SA_NAME="basic-test-mount-sa-${ARCH}-${AUTH_TYPE}"

# RESOURCE_PREFIX is inserted into secret/parameter names for collision avoidance
# across different test suites sharing the same account. Exported for envsubst
# to interpolate in the SecretProviderClass YAML template.
# P is a short alias used in test assertions to keep lines readable.
export RESOURCE_PREFIX="${RESOURCE_PREFIX:-}"
P="$RESOURCE_PREFIX"

# These must be set by run-tests.sh before invoking bats.
: "${INSTALL_METHOD:?must be set by run-tests.sh (addon, helm, or yaml)}"
: "${INFRA_BACKEND:?must be set by run-tests.sh (cfn or eksctl)}"

# Account number is needed in the SPC template for constructing full secret ARNs
export ACCOUNT_NUMBER
ACCOUNT_NUMBER=$(aws --region "$REGION" sts get-caller-identity --query Account --output text) || {
	echo "Error: Failed to fetch AWS account number. Check credentials and REGION ($REGION)." >&2
	exit 1
}

# ============================================================
# Logging
# ============================================================
# Each arch-auth combo gets a distinct color so parallel log output is distinguishable.

case "${ARCH}-${AUTH_TYPE}" in
	x64-irsa) LOG_COLOR='\033[0;36m' ;; x64-pod-identity) LOG_COLOR='\033[0;35m' ;;
	arm-irsa) LOG_COLOR='\033[0;34m' ;; arm-pod-identity) LOG_COLOR='\033[0;33m' ;;
	*)        LOG_COLOR='\033[0m' ;;
esac
NC='\033[0m'

# Log a message with color-coded prefix for the current arch-auth combo.
log() { echo -e "${LOG_COLOR}[$(date -Iseconds)] [${ARCH}-${AUTH_TYPE}] $1${NC}" >&3; }

# ============================================================
# Kubectl helper
# ============================================================

# Run kubectl against the test cluster with the correct kubeconfig and namespace.
kctl() { kubectl --kubeconfig="$KUBECONFIG_FILE" --namespace "$NAMESPACE" "$@"; }

# ============================================================
# CloudFormation helper
# ============================================================

# Retrieve a single output value from the cluster's CloudFormation stack.
get_stack_output() {
	aws cloudformation describe-stacks --stack-name "$CLUSTER_NAME" --region "$REGION" \
		--query "Stacks[0].Outputs[?OutputKey=='${1}'].OutputValue" --output text
}

# ============================================================
# Exported variables for envsubst (used in YAML templates)
# ============================================================
# POD_IDENTITY_PARAM is injected into the SecretProviderClass template.
# When using Pod Identity, it adds 'usePodIdentity: "true"' to the parameters block.
if [[ "$AUTH_TYPE" == "pod-identity" ]]; then
	export POD_IDENTITY_PARAM=$'\n    usePodIdentity: "true"'
else
	export POD_IDENTITY_PARAM=""
fi

export KUBECONFIG_FILE="/tmp/integ-kubeconfig-${ARCH}-${AUTH_TYPE}"
FAIL_MARKER="/tmp/integ-failfast-${ARCH}-${AUTH_TYPE}"

# ============================================================
# Auth setup
# ============================================================
# How auth is configured depends on the infrastructure backend:
#
# CFN backend: The IRSA role and Pod Identity association are created by the
#   CloudFormation stack. We just need to create the K8s ServiceAccount and
#   annotate it with the role ARN from the stack outputs.
#
# eksctl backend: We use eksctl commands to create the OIDC provider, IAM
#   service account (IRSA), or Pod Identity addon + association imperatively.

# Configure pod authentication (IRSA or Pod Identity) for the test service account.
setup_auth() {
	if [[ "$INFRA_BACKEND" == "cfn" ]]; then
		log "Creating K8s ServiceAccount ($AUTH_TYPE)"
		kctl create serviceaccount "$SA_NAME" --dry-run=client -o yaml | kctl apply -f - >&3 2>&1
		if [[ "$AUTH_TYPE" == "irsa" ]]; then
			# Read the IRSA role ARN that the CFN stack created
			local irsa_role_arn
			irsa_role_arn=$(get_stack_output "IRSARoleArn")
			kctl annotate serviceaccount "$SA_NAME" "eks.amazonaws.com/role-arn=$irsa_role_arn" --overwrite >&3 2>&1
		fi
		# Pod Identity: no K8s-side setup needed — the CFN stack created the association
	else
		local partition
		partition=$(aws sts get-caller-identity --query Arn --output text | cut -d: -f2)
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
			eksctl create addon --name eks-pod-identity-agent --cluster "$CLUSTER_NAME" --region "$REGION" --wait >&3 2>&1
			log "Creating Pod Identity association"
			eksctl create podidentityassociation \
				--cluster "$CLUSTER_NAME" --namespace "$NAMESPACE" --region "$REGION" \
				--service-account-name "$SA_NAME" --role-arn "$POD_IDENTITY_ROLE_ARN" \
				--create-service-account true >&3 2>&1
		fi
	fi
}

# ============================================================
# Driver/provider installation
# ============================================================
# Three install methods:
#   addon — Install via EKS add-on (includes both CSI driver and provider)
#   helm  — Install CSI driver via Helm, then provider via YAML manifest (test below)
#   yaml  — Same as helm (the provider YAML is applied in the "Install aws provider" test)

# Install the CSI driver and/or provider based on the selected install method.
install_driver() {
	if [[ "$INSTALL_METHOD" == "addon" ]]; then
		local version_flag=""
		if [[ -n "${ADDON_VERSION:-}" ]]; then
			version_flag="--addon-version $ADDON_VERSION"
		fi
		log "Installing via EKS addon"
		aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-secrets-store-csi-driver-provider \
			--configuration-values "file://addon_config_values.yaml" $version_flag --region "$REGION" >&3 2>&1
		aws eks wait addon-active --cluster-name "$CLUSTER_NAME" --addon-name aws-secrets-store-csi-driver-provider \
			--region "$REGION" >&3 2>&1
	elif [[ "$INSTALL_METHOD" == "helm" ]]; then
		# Helm installs only the CSI driver. The provider itself is installed
		# in the "Install aws provider" test case using the PRIVREPO image.
		log "Installing secrets-store-csi-driver via Helm"
		helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
		KUBECONFIG="$KUBECONFIG_FILE" helm --namespace="$NAMESPACE" install csi-secrets-store \
			secrets-store-csi-driver/secrets-store-csi-driver \
			--set enableSecretRotation=true --set rotationPollInterval=15s --set syncSecret.enabled=true \
			--set tokenRequests[0].audience=sts.amazonaws.com --set tokenRequests[1].audience=pods.eks.amazonaws.com \
			--timeout "$WAIT_LONG" --wait
	fi
}

# ============================================================
# bats lifecycle
# ============================================================

# One-time setup: write kubeconfig, wait for nodes, install driver, configure auth.
setup_file() {
	rm -f "$FAIL_MARKER"
	log "Setting up $CLUSTER_NAME"

	# Write kubeconfig for the cluster (created by run-tests.sh via infra.sh deploy)
	bash infra.sh write-kubeconfig "${ARCH}-${AUTH_TYPE}" >&3 2>&1

	# Wait for nodes — fast no-op if nodes are already Ready (cfn stacks take
	# long enough that nodes are usually ready), but necessary as a safety net
	kctl wait --for=condition=Ready node --all --timeout="$WAIT_LONG" >&3 2>&1

	if ! install_driver; then
		log "ERROR: install_driver failed"
		touch "$FAIL_MARKER"
		return 1
	fi
	if ! setup_auth; then
		log "ERROR: setup_auth failed"
		touch "$FAIL_MARKER"
		return 1
	fi

	# Pull secret for private test images hosted on ghcr.io (GitHub Actions only)
	if [[ -n "${GHCR_TOKEN:-}" ]]; then
		log "Creating ghcr.io image pull secret"
		kctl create secret docker-registry ghcr-credentials \
			--docker-server=ghcr.io --docker-username=github --docker-password="$GHCR_TOKEN"
	fi

	log "Setup completed"
}

# Skip remaining tests if a previous test in this file failed (fail-fast).
setup() {
	if [[ -f "$FAIL_MARKER" ]]; then skip "Skipped due to earlier failure"; fi
}

# On test failure, dump diagnostics before skipping remaining tests (fail-fast).
# This captures pod status, provider logs, and cluster events for debugging.
teardown() {
	if [[ "$BATS_TEST_COMPLETED" == "1" ]]; then return; fi
	touch "$FAIL_MARKER"
	log "FAILED: ${BATS_TEST_DESCRIPTION} — dumping diagnostics"
	echo "# ===== BEGIN DIAGNOSTICS =====" >&3
	{ echo "# --- pod status ---"
	  kctl get pods -o wide 2>&1 | sed 's/^/#   /'; } >&3 || true
	echo "# --- provider pods ---" >&3
	for pod in $(kctl get pods -l app=csi-secrets-store-provider-aws -o name 2>/dev/null); do
		{ echo "# describe $pod:"
		  kctl describe "$pod" 2>&1 | tail -20 | sed 's/^/#   /'; } >&3 || true
		{ echo "# logs $pod:"
		  kctl logs "$pod" --tail=20 2>&1 | sed 's/^/#   /'; } >&3 || true
	done
	{ echo "# --- test pod ---"
	  kctl describe "pod/$POD_NAME" 2>&1 | tail -20 | sed 's/^/#   /'; } >&3 || true
	{ echo "# --- events ---"
	  kctl get events --sort-by=.lastTimestamp 2>&1 | tail -15 | sed 's/^/#   /'; } >&3 || true
	echo "# ===== END DIAGNOSTICS =====" >&3
}

# Clean up kubeconfig temp file.
teardown_file() { rm -f "$FAIL_MARKER" "$KUBECONFIG_FILE"; log "Teardown completed"; }

# ============================================================
# Test helpers
# ============================================================

# Poll a mounted secret file until its content matches the expected value.
# Usage: wait_for_rotation <mount_path> <expected_value> [timeout_seconds]
wait_for_rotation() {
	local path="$1" expected="$2" timeout="${3:-60}" elapsed=0
	while (( elapsed < timeout )); do
		local actual
		actual=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/$path" 2>/dev/null) || true
		if [[ "${actual//$'\r'}" == "$expected" ]]; then return 0; fi
		sleep 5
		(( elapsed += 5 ))
	done
	log "Timed out waiting for $path to become '$expected' (last: '${actual:-}')"
	return 1
}

# Validates that a JSON secret was correctly split into individual key files
# via jmesPath, and that the corresponding K8s Secret was synced.
# Called with env vars: USERNAME_ALIAS, USERNAME, PASSWORD_ALIAS, PASSWORD,
#                       SECRET_FILE_NAME, SECRET_FILE_CONTENT, K8_SECRET_NAME
validate_jmes_mount() {
	# Verify individual key files were mounted
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/$USERNAME_ALIAS")
	[[ "${result//$'\r'}" == "$USERNAME" ]]
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/$PASSWORD_ALIAS")
	[[ "${result//$'\r'}" == "$PASSWORD" ]]

	# Verify the full JSON secret file was also mounted
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/$SECRET_FILE_NAME")
	[[ "${result//$'\r'}" == "$SECRET_FILE_CONTENT" ]]

	# Verify the synced K8s Secret contains the extracted values
	run kctl get secret "$K8_SECRET_NAME"
	[ "$status" -eq 0 ]
	result=$(kctl get secret "$K8_SECRET_NAME" -o jsonpath="{.data.username}" | base64 -d)
	[[ "$result" == "$USERNAME" ]]
	result=$(kctl get secret "$K8_SECRET_NAME" -o jsonpath="{.data.password}" | base64 -d)
	[[ "$result" == "$PASSWORD" ]]
}

# ============================================================
# Tests: Addon schema validation
# ============================================================

@test "addon config schema options applied" {
	if [[ "$INSTALL_METHOD" != "addon" ]]; then skip "Only applies to addon installs"; fi
	log "Verifying addon config schema options"
	local addon_ns="aws-secrets-manager" ds="daemonset/aws-secrets-store-csi-driver-provider"
	dskctl() { kubectl --kubeconfig="$KUBECONFIG_FILE" --namespace "$addon_ns" "$@"; }

	[[ "$(dskctl get "$ds" -o jsonpath='{.spec.template.metadata.labels.integ-test}')" == "true" ]]
	[[ "$(dskctl get "$ds" -o jsonpath='{.spec.template.metadata.annotations.integ-test-annotation}')" == "true" ]]
	[[ "$(dskctl get "$ds" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}')" == "50m" ]]
	[[ "$(dskctl get "$ds" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}')" == "100Mi" ]]
	[[ "$(dskctl get "$ds" -o jsonpath='{.spec.template.spec.tolerations[?(@.operator=="Exists")].operator}')" == "Exists" ]]
	run dskctl get "$ds" -o jsonpath='{.spec.template.spec.containers[0].args}'
	assert_success
}

# ============================================================
# Tests: Provider installation (non-addon only)
# ============================================================

@test "Install aws provider" {
	if [[ "$INSTALL_METHOD" == "addon" ]]; then skip "Provider installed via addon"; fi
	log "Installing AWS provider"
	# Substitute the placeholder image in the provider YAML with the actual test image
	local image="${PRIVREPO}${PRIVTAG:+:${PRIVTAG}}" yaml
	yaml=$(sed "s|\${PRIVREPO}\${PRIVTAG:+:}\${PRIVTAG}|${image}|" "$PROVIDER_YAML")
	if [[ -n "${GHCR_TOKEN:-}" ]]; then
		yaml=$(echo "$yaml" | sed '/hostNetwork: false/a\
      imagePullSecrets:\
        - name: ghcr-credentials')
	fi
	echo "$yaml" | kctl apply -f -
	kctl wait --for=condition=Ready --timeout="$WAIT_LONG" pod -l app=csi-secrets-store-provider-aws
	run kctl get pod -l app=csi-secrets-store-provider-aws
	assert_success
}

# ============================================================
# Tests: RBAC and CSI token validation
# ============================================================

@test "provider does not have serviceaccounts/token create permission" {
	log "Verifying serviceaccounts/token create permission is absent"
	local rules
	rules=$(kctl get clusterrole -l app=csi-secrets-store-provider-aws -o json 2>/dev/null) \
		|| rules=$(kctl get clusterrole csi-secrets-store-provider-aws-cluster-role -o json)
	if echo "$rules" | grep -q '"serviceaccounts/token"'; then
		echo "FAIL: ClusterRole still grants serviceaccounts/token permission" >&3
		echo "$rules" | grep -A2 'serviceaccounts/token' >&3
		return 1
	fi
}

# ============================================================
# Tests: SecretProviderClass and pod deployment
# ============================================================

@test "secretproviderclasses crd is established" {
	log "Verifying secretproviderclasses CRD"
	kctl wait --for=condition=established --timeout="$WAIT" crd/secretproviderclasses.secrets-store.csi.x-k8s.io
	run kctl get crd/secretproviderclasses.secrets-store.csi.x-k8s.io
	assert_success
}

@test "deploy aws secretproviderclass crd" {
	log "Deploying SecretProviderClass"
	local rendered
	rendered=$(envsubst < "templates/BasicTestMountSPC.yaml.template")
	if echo "$rendered" | grep -qE '\$\{[A-Z_]+\}'; then
		echo "Error: unsubstituted variables in SPC template:" >&3
		echo "$rendered" | grep -E '\$\{[A-Z_]+\}' >&3
		return 1
	fi
	echo "$rendered" | kctl apply -f -
	run kctl get secretproviderclasses.secrets-store.csi.x-k8s.io/"basic-test-mount-spc-${ARCH}-${AUTH_TYPE}" -o jsonpath='{.spec.provider}'
	[[ "$output" == "aws" ]]
}

@test "CSI inline volume test with pod portability" {
	log "Deploying test pod"
	local rendered
	rendered=$(envsubst < "templates/BasicTestMount.yaml.template")
	if echo "$rendered" | grep -qE '\$\{[A-Z_]+\}'; then
		echo "Error: unsubstituted variables in pod template:" >&3
		echo "$rendered" | grep -E '\$\{[A-Z_]+\}' >&3
		return 1
	fi
	echo "$rendered" | kctl apply -f -
	kctl wait --for=condition=Ready --timeout="$WAIT_LONG" "pod/$POD_NAME"
	run kctl get pod/"$POD_NAME"
	assert_success
}

# ============================================================
# Tests: Secret rotation
# ============================================================
# These tests verify that the CSI driver's rotation reconciler picks up
# value changes. The rotation poll interval is set to 15s in the driver config.
# We poll until the new value appears rather than using a fixed sleep.

@test "CSI inline volume test with rotation - parameter store" {
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/ParameterStoreRotationTest${P}-${ARCH}-${AUTH_TYPE}")
	[[ "${result//$'\r'}" == "BeforeRotation" ]]
	aws ssm put-parameter --name "ParameterStoreRotationTest${P}-${ARCH}-${AUTH_TYPE}" --value AfterRotation --type SecureString --overwrite --region "$REGION"
	wait_for_rotation "ParameterStoreRotationTest${P}-${ARCH}-${AUTH_TYPE}" "AfterRotation"
}

@test "CSI inline volume test with rotation - secrets manager" {
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/SecretsManagerRotationTest${P}-${ARCH}-${AUTH_TYPE}")
	[[ "${result//$'\r'}" == "BeforeRotation" ]]
	aws secretsmanager put-secret-value --secret-id "SecretsManagerRotationTest${P}-${ARCH}-${AUTH_TYPE}" --secret-string AfterRotation --region "$REGION"
	wait_for_rotation "SecretsManagerRotationTest${P}-${ARCH}-${AUTH_TYPE}" "AfterRotation"
}

# ============================================================
# Tests: Basic secret/parameter reads
# ============================================================

@test "read ssm parameters from pod" {
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/ParameterStoreTest1${P}-${ARCH}-${AUTH_TYPE}")
	[[ "${result//$'\r'}" == "ParameterStoreTest1Value" ]]
	# ParameterStoreTest2 uses objectAlias, so the mount path is the alias (no arch-auth suffix)
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/ParameterStoreTest2${P}")
	[[ "${result//$'\r'}" == "ParameterStoreTest2Value" ]]
}

@test "read SecureString SSM parameter from pod" {
	log "Overwriting parameter as SecureString and verifying read"
	aws ssm put-parameter --name "ParameterStoreSecureTest${P}-${ARCH}-${AUTH_TYPE}" \
		--value "SecureStringTestValue" --type SecureString --overwrite --region "$REGION"
	wait_for_rotation "ParameterStoreSecureTest${P}-${ARCH}-${AUTH_TYPE}" "SecureStringTestValue"
}

@test "read secrets manager secrets from pod" {
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/SecretsManagerTest1${P}-${ARCH}-${AUTH_TYPE}")
	[[ "${result//$'\r'}" == "SecretsManagerTest1Value" ]]
	# SecretsManagerTest2 uses objectAlias + failoverObject for cross-region failover testing
	result=$(kctl exec "$POD_NAME" -- cat "/mnt/secrets-store/SecretsManagerTest2${P}")
	[[ "${result//$'\r'}" == "SecretsManagerTest2Value" ]]
}

# ============================================================
# Tests: Cross-region failover
# ============================================================

@test "failover to secondary region when primary secret is unavailable" {
	log "Testing cross-region failover for SecretsManagerTest2"
	# Delete the primary region secret to force failover
	aws secretsmanager delete-secret --secret-id "SecretsManagerTest2${P}-${ARCH}-${AUTH_TYPE}" \
		--force-delete-without-recovery --region "$REGION"
	# Wait for CSI driver rotation to pick up the change and fall back to failover region
	wait_for_rotation "SecretsManagerTest2${P}" "SecretsManagerTest2Value"
	# Restore the primary secret and verify it's accessible again
	aws secretsmanager create-secret --name "SecretsManagerTest2${P}-${ARCH}-${AUTH_TYPE}" \
		--secret-string "SecretsManagerTest2Value" --region "$REGION" >/dev/null
	wait_for_rotation "SecretsManagerTest2${P}" "SecretsManagerTest2Value"
}

# ============================================================
# Tests: JMES path extraction with rotation
# ============================================================
# These tests verify that individual JSON keys can be extracted from a secret
# and mounted as separate files, and that rotation updates propagate to them.

@test "jmesPath for parameter store with rotation" {
	JSON_CONTENT='{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}'
	USERNAME_ALIAS=ssmUsername USERNAME=ParameterStoreUser PASSWORD_ALIAS=ssmPassword PASSWORD=PasswordForParameterStore \
	SECRET_FILE_NAME="jsonSsm${P}-${ARCH}-${AUTH_TYPE}" SECRET_FILE_CONTENT="$JSON_CONTENT" K8_SECRET_NAME=json-ssm validate_jmes_mount

	UPDATED_JSON_CONTENT='{"username": "ParameterStoreUserUpdated", "password": "PasswordForParameterStoreUpdated"}'
	aws ssm put-parameter --name "jsonSsm${P}-${ARCH}-${AUTH_TYPE}" --value "$UPDATED_JSON_CONTENT" --type SecureString --overwrite --region "$REGION"
	wait_for_rotation "jsonSsm${P}-${ARCH}-${AUTH_TYPE}" "$UPDATED_JSON_CONTENT"
	USERNAME_ALIAS=ssmUsername USERNAME=ParameterStoreUserUpdated PASSWORD_ALIAS=ssmPassword PASSWORD=PasswordForParameterStoreUpdated \
	SECRET_FILE_NAME="jsonSsm${P}-${ARCH}-${AUTH_TYPE}" SECRET_FILE_CONTENT="$UPDATED_JSON_CONTENT" K8_SECRET_NAME=json-ssm validate_jmes_mount
}

@test "jmesPath for secrets manager with rotation" {
	JSON_CONTENT='{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}'
	USERNAME_ALIAS=secretsManagerUsername USERNAME=SecretsManagerUser PASSWORD_ALIAS=secretsManagerPassword \
	PASSWORD=PasswordForSecretsManager SECRET_FILE_NAME="secretsManagerJson${P}-${ARCH}-${AUTH_TYPE}" SECRET_FILE_CONTENT="$JSON_CONTENT" \
	K8_SECRET_NAME=secrets-manager-json validate_jmes_mount

	UPDATED_JSON_CONTENT='{"username": "SecretsManagerUserUpdated", "password": "PasswordForSecretsManagerUpdated"}'
	aws secretsmanager put-secret-value --secret-id "secretsManagerJson${P}-${ARCH}-${AUTH_TYPE}" --secret-string "$UPDATED_JSON_CONTENT" --region "$REGION"
	wait_for_rotation "secretsManagerJson${P}-${ARCH}-${AUTH_TYPE}" "$UPDATED_JSON_CONTENT"
	USERNAME_ALIAS=secretsManagerUsername USERNAME=SecretsManagerUserUpdated PASSWORD_ALIAS=secretsManagerPassword \
	PASSWORD=PasswordForSecretsManagerUpdated SECRET_FILE_NAME="secretsManagerJson${P}-${ARCH}-${AUTH_TYPE}" SECRET_FILE_CONTENT="$UPDATED_JSON_CONTENT" \
	K8_SECRET_NAME=secrets-manager-json validate_jmes_mount
}

# ============================================================
# Tests: Kubernetes Secret sync
# ============================================================
# The CSI driver can sync mounted secrets to native K8s Secrets (configured via
# secretObjects in the SecretProviderClass). Deleting the pod should also delete
# the synced Secret.

@test "sync with Kubernetes Secret" {
	run kctl get secret secret
	[ "$status" -eq 0 ]
	result=$(kctl get secret secret -o jsonpath="{.data.username}" | base64 -d)
	[[ "$result" == "SecretUser" ]]
}

# ============================================================
# Tests: Negative / error paths
# ============================================================

@test "pod with nonexistent secret fails to start" {
	log "Testing error path: nonexistent secret reference"
	kctl apply -f - <<-EOF
	apiVersion: secrets-store.csi.x-k8s.io/v1
	kind: SecretProviderClass
	metadata:
	  name: bad-spc-${ARCH}-${AUTH_TYPE}
	spec:
	  provider: aws
	  parameters:
	    region: ${REGION}
	    objects: |
	      - objectName: "nonexistent-secret-that-does-not-exist"
	        objectType: "secretsmanager"
	EOF
	kctl apply -f - <<-EOF
	apiVersion: v1
	kind: Pod
	metadata:
	  name: bad-mount-pod-${ARCH}-${AUTH_TYPE}
	spec:
	  serviceAccountName: ${SA_NAME}
	  terminationGracePeriodSeconds: 0
	  containers:
	    - image: ${BUSYBOX_IMAGE}
	      name: busybox
	      command: ["/bin/sleep", "10000"]
	      volumeMounts:
	        - name: secrets-store-inline
	          mountPath: "/mnt/secrets-store"
	          readOnly: true
	  volumes:
	    - name: secrets-store-inline
	      csi:
	        driver: secrets-store.csi.k8s.io
	        readOnly: true
	        volumeAttributes:
	          secretProviderClass: "bad-spc-${ARCH}-${AUTH_TYPE}"
	EOF
	# Pod should fail to become Ready because the secret doesn't exist
	run kctl wait --for=condition=Ready --timeout=60s "pod/bad-mount-pod-${ARCH}-${AUTH_TYPE}"
	[[ "$status" -ne 0 ]]
	# Verify the pod has a mount-related error in events
	run kctl get events --field-selector "involvedObject.name=bad-mount-pod-${ARCH}-${AUTH_TYPE}" -o jsonpath='{.items[*].message}'
	[[ "$output" == *"FailedMount"* ]] || [[ "$output" == *"failed to mount"* ]] || [[ "$output" == *"rpc error"* ]]
	# Clean up
	kctl delete pod "bad-mount-pod-${ARCH}-${AUTH_TYPE}" --force --grace-period=0 2>/dev/null || true
	kctl delete secretproviderclass "bad-spc-${ARCH}-${AUTH_TYPE}" 2>/dev/null || true
}

@test "delete pod - synced secret should also be deleted" {
	run kctl delete pod "$POD_NAME"
	assert_success
	kctl wait --for=delete --timeout="$WAIT" secret/secret
}
