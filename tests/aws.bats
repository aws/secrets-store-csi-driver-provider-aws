#!/usr/bin/env bats

load helpers

WAIT_TIME=120
SLEEP_TIME=1
PROVIDER_YAML=../deployment/private-installer.yaml
NAMESPACE=kube-system
CLUSTER_NAME=integ-cluster
CLUSTER_NAME_ARM=integ-cluster-arm
POD_NAME_IRSA=basic-test-mount-irsa
POD_NAME_POD_IDENTITY=basic-test-mount-pod-identity
export REGION=us-west-2
export FAILOVERREGION=us-east-2
export ACCOUNT_NUMBER=$(aws --region $REGION sts get-caller-identity --query Account --output text)

if [[ -z "${PRIVREPO}" ]]; then
    echo "Error: PRIVREPO is not specified" >&2
    return 1
fi

if [[ -z "${NODE_TYPE}" ]]; then
    NODE_TYPE=m5.large
fi

if [[ -z "${NODE_TYPE_ARM}" ]]; then
    NODE_TYPE_ARM=m6g.large
fi

setup_file() {
    progress_msg $CYAN "Starting setup for both x64 and ARM clusters with IRSA and Pod Identity authentication"

    progress_msg $CYAN "Creating x64 cluster: $CLUSTER_NAME"
    #Create and initialize x64 cluster
    eksctl create cluster \
        --name $CLUSTER_NAME \
        --node-type $NODE_TYPE \
        --nodes 3 \
        --region $REGION

    progress_msg $CYAN "Associating OIDC provider for x64 cluster"
    eksctl utils associate-iam-oidc-provider --name $CLUSTER_NAME --approve --region $REGION

    progress_msg $CYAN "Creating IRSA service account for x64 cluster"
    # Create IRSA service account for x64 cluster
    eksctl create iamserviceaccount \
        --name basic-test-mount-sa-irsa \
        --namespace $NAMESPACE \
        --cluster $CLUSTER_NAME \
        --attach-policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess \
        --attach-policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite \
        --override-existing-serviceaccounts \
        --approve \
        --region $REGION

    progress_msg $CYAN "Installing Pod Identity Agent for x64 cluster"
    eksctl create addon \
        --name eks-pod-identity-agent \
        --cluster $CLUSTER_NAME \
        --region $REGION

    progress_msg $CYAN "Creating IAM role for Pod Identity on x64 cluster"
    # Create IAM role for Pod Identity on x64 cluster
    ROLE_NAME="basic-test-mount-pod-identity-role-x64"
    aws iam create-role --role-name $ROLE_NAME --assume-role-policy-document '{
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
    }' --region $REGION || true

    progress_msg $CYAN "Attaching policies to Pod Identity role for x64 cluster"
    aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess --region $REGION
    aws iam attach-role-policy --role-name $ROLE_NAME --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite --region $REGION

    progress_msg $CYAN "Creating service account for Pod Identity on x64 cluster"
    # Create service account for Pod Identity on x64 cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME | head -1)

    progress_msg $CYAN "Creating Pod Identity association for x64 cluster"
    # Create Pod Identity association for x64 cluster
    eksctl create podidentityassociation \
        --cluster $CLUSTER_NAME \
        --namespace $NAMESPACE \
        --service-account-name basic-test-mount-sa-pod-identity \
        --role-arn arn:aws:iam::$ACCOUNT_NUMBER:role/$ROLE_NAME \
        --region $REGION || true

    progress_msg $CYAN "Installing CSI secret driver on x64 cluster"
    #Install csi secret driver on x64 cluster
    helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME | head -1)
    helm --namespace=$NAMESPACE install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver --set enableSecretRotation=true --set rotationPollInterval=15s --set syncSecret.enabled=true

    progress_msg $CYAN "Creating ARM cluster: $CLUSTER_NAME_ARM"
    #Create and initialize ARM cluster
    eksctl create cluster \
        --name $CLUSTER_NAME_ARM \
        --node-type $NODE_TYPE_ARM \
        --nodes 3 \
        --region $REGION

    progress_msg $CYAN "Associating OIDC provider for ARM cluster"
    eksctl utils associate-iam-oidc-provider --name $CLUSTER_NAME_ARM --approve --region $REGION

    progress_msg $CYAN "Creating IRSA service account for ARM cluster"
    # Create IRSA service account for ARM cluster
    eksctl create iamserviceaccount \
        --name basic-test-mount-sa-irsa \
        --namespace $NAMESPACE \
        --cluster $CLUSTER_NAME_ARM \
        --attach-policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess \
        --attach-policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite \
        --override-existing-serviceaccounts \
        --approve \
        --region $REGION

    progress_msg $CYAN "Installing Pod Identity Agent for ARM cluster"
    eksctl create addon \
        --name eks-pod-identity-agent \
        --cluster $CLUSTER_NAME_ARM \
        --region $REGION

    progress_msg $CYAN "Creating IAM role for Pod Identity on ARM cluster"
    # Create IAM role for Pod Identity on ARM cluster
    ROLE_NAME_ARM="basic-test-mount-pod-identity-role-arm"
    aws iam create-role --role-name $ROLE_NAME_ARM --assume-role-policy-document '{
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
    }' --region $REGION || true

    progress_msg $CYAN "Attaching policies to Pod Identity role for ARM cluster"
    aws iam attach-role-policy --role-name $ROLE_NAME_ARM --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess --region $REGION
    aws iam attach-role-policy --role-name $ROLE_NAME_ARM --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite --region $REGION

    progress_msg $CYAN "Creating service account for Pod Identity on ARM cluster"
    # Create service account for Pod Identity on ARM cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME_ARM | head -1)
    kubectl create serviceaccount basic-test-mount-sa-pod-identity --namespace $NAMESPACE || true

    progress_msg $CYAN "Creating Pod Identity association for ARM cluster"
    # Create Pod Identity association for ARM cluster
    eksctl create podidentityassociation \
        --cluster $CLUSTER_NAME_ARM \
        --namespace $NAMESPACE \
        --service-account-name basic-test-mount-sa-pod-identity \
        --role-arn arn:aws:iam::$ACCOUNT_NUMBER:role/$ROLE_NAME_ARM \
        --region $REGION || true

    progress_msg $CYAN "Installing CSI secret driver on ARM cluster"
    #Install csi secret driver on ARM cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME_ARM | head -1)
    helm --namespace=$NAMESPACE install csi-secrets-store-arm secrets-store-csi-driver/secrets-store-csi-driver --set enableSecretRotation=true --set rotationPollInterval=15s --set syncSecret.enabled=true

    progress_msg $CYAN "Creating test secrets in primary region ($REGION)"
    #Create test secrets
    aws secretsmanager create-secret --name SecretsManagerTest1 --secret-string SecretsManagerTest1Value --region $REGION
    aws secretsmanager create-secret --name SecretsManagerTest2 --secret-string SecretsManagerTest2Value --region $REGION
    aws secretsmanager create-secret --name SecretsManagerSync --secret-string SecretUser --region $REGION

    progress_msg $CYAN "Creating test secrets in failover region ($FAILOVERREGION)"
    aws secretsmanager create-secret --name SecretsManagerTest1 --secret-string SecretsManagerTest1Value --region $FAILOVERREGION
    aws secretsmanager create-secret --name SecretsManagerTest2 --secret-string SecretsManagerTest2Value --region $FAILOVERREGION
    aws secretsmanager create-secret --name SecretsManagerSync --secret-string SecretUser --region $FAILOVERREGION

    progress_msg $CYAN "Creating test parameters in primary region ($REGION)"
    aws ssm put-parameter --name ParameterStoreTest1 --value ParameterStoreTest1Value --type SecureString --region $REGION
    aws ssm put-parameter --name ParameterStoreTestWithLongName --value ParameterStoreTest2Value --type SecureString --region $REGION

    progress_msg $CYAN "Creating test parameters in failover region ($FAILOVERREGION)"
    aws ssm put-parameter --name ParameterStoreTest1 --value ParameterStoreTest1Value --type SecureString --region $FAILOVERREGION
    aws ssm put-parameter --name ParameterStoreTestWithLongName --value ParameterStoreTest2Value --type SecureString --region $FAILOVERREGION

    progress_msg $CYAN "Creating rotation test resources in both regions"
    aws ssm put-parameter --name ParameterStoreRotationTest --value BeforeRotation --type SecureString --region $REGION
    aws secretsmanager create-secret --name SecretsManagerRotationTest --secret-string BeforeRotation --region $REGION
    aws ssm put-parameter --name ParameterStoreRotationTest --value BeforeRotation --type SecureString --region $FAILOVERREGION
    aws secretsmanager create-secret --name SecretsManagerRotationTest --secret-string BeforeRotation --region $FAILOVERREGION

    progress_msg $CYAN "Creating JSON test resources in both regions"
    aws secretsmanager create-secret --name secretsManagerJson --secret-string '{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}' --region $REGION
    aws ssm put-parameter --name jsonSsm --value '{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}' --type SecureString --region $REGION
    aws secretsmanager create-secret --name secretsManagerJson --secret-string '{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}' --region $FAILOVERREGION
    aws ssm put-parameter --name jsonSsm --value '{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}' --type SecureString --region $FAILOVERREGION

    progress_msg $CYAN "Setup completed successfully!"
}

teardown_file() {
    progress_msg $CYAN "Starting cleanup process"

    progress_msg $CYAN "Cleaning up Pod Identity associations"
    # Clean up Pod Identity associations and roles
    aws eks delete-pod-identity-association \
        --cluster-name $CLUSTER_NAME \
        --association-id $(aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME --region $REGION --query "associations[?serviceAccount=='basic-test-mount-sa-pod-identity'].associationId" --output text) \
        --region $REGION || true

    aws eks delete-pod-identity-association \
        --cluster-name $CLUSTER_NAME_ARM \
        --association-id $(aws eks list-pod-identity-associations --cluster-name $CLUSTER_NAME_ARM --region $REGION --query "associations[?serviceAccount=='basic-test-mount-sa-pod-identity'].associationId" --output text) \
        --region $REGION || true

    progress_msg $CYAN "Cleaning up IAM roles for Pod Identity"
    aws iam detach-role-policy --role-name basic-test-mount-pod-identity-role-x64 --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess || true
    aws iam detach-role-policy --role-name basic-test-mount-pod-identity-role-x64 --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite || true
    aws iam delete-role --role-name basic-test-mount-pod-identity-role-x64 || true

    aws iam detach-role-policy --role-name basic-test-mount-pod-identity-role-arm --policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess || true
    aws iam detach-role-policy --role-name basic-test-mount-pod-identity-role-arm --policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite || true
    aws iam delete-role --role-name basic-test-mount-pod-identity-role-arm || true

    progress_msg $CYAN "Deleting x64 cluster: $CLUSTER_NAME"
    eksctl delete cluster \
        --name $CLUSTER_NAME \
        --region $REGION

    progress_msg $CYAN "Deleting ARM cluster: $CLUSTER_NAME_ARM"
    eksctl delete cluster \
        --name $CLUSTER_NAME_ARM \
        --region $REGION

    progress_msg $CYAN "Cleaning up test secrets in primary region ($REGION)"
    aws secretsmanager delete-secret --secret-id SecretsManagerTest1 --force-delete-without-recovery --region $REGION
    aws secretsmanager delete-secret --secret-id SecretsManagerTest2 --force-delete-without-recovery --region $REGION
    aws secretsmanager delete-secret --secret-id SecretsManagerSync --force-delete-without-recovery --region $REGION

    progress_msg $CYAN "Cleaning up test secrets in failover region ($FAILOVERREGION)"
    aws secretsmanager delete-secret --secret-id SecretsManagerTest1 --force-delete-without-recovery --region $FAILOVERREGION
    aws secretsmanager delete-secret --secret-id SecretsManagerTest2 --force-delete-without-recovery --region $FAILOVERREGION
    aws secretsmanager delete-secret --secret-id SecretsManagerSync --force-delete-without-recovery --region $FAILOVERREGION

    progress_msg $CYAN "Cleaning up test parameters in primary region ($REGION)"
    aws ssm delete-parameter --name ParameterStoreTest1 --region $REGION
    aws ssm delete-parameter --name ParameterStoreTestWithLongName --region $REGION

    progress_msg $CYAN "Cleaning up test parameters in failover region ($FAILOVERREGION)"
    aws ssm delete-parameter --name ParameterStoreTest1 --region $FAILOVERREGION
    aws ssm delete-parameter --name ParameterStoreTestWithLongName --region $FAILOVERREGION

    progress_msg $CYAN "Cleaning up rotation test resources in both regions"
    aws ssm delete-parameter --name ParameterStoreRotationTest --region $REGION
    aws secretsmanager delete-secret --secret-id SecretsManagerRotationTest --force-delete-without-recovery --region $REGION
    aws ssm delete-parameter --name ParameterStoreRotationTest --region $FAILOVERREGION
    aws secretsmanager delete-secret --secret-id SecretsManagerRotationTest --force-delete-without-recovery --region $FAILOVERREGION

    progress_msg $CYAN "Cleaning up JSON test resources in both regions"
    aws ssm delete-parameter --name jsonSsm --region $REGION
    aws secretsmanager delete-secret --secret-id secretsManagerJson --force-delete-without-recovery --region $REGION
    aws ssm delete-parameter --name jsonSsm --region $FAILOVERREGION
    aws secretsmanager delete-secret --secret-id secretsManagerJson --force-delete-without-recovery --region $FAILOVERREGION

    progress_msg $CYAN "Cleanup completed successfully!"
}

@test "Install aws provider" {
    progress_msg $CYAN "Installing AWS provider on both clusters"

    progress_msg $CYAN "Installing AWS provider on x64 cluster"
    # Install on x64 cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME | head -1)
    envsubst < $PROVIDER_YAML | kubectl apply -f -
    cmd="kubectl --namespace $NAMESPACE wait --for=condition=Ready --timeout=60s pod -l app=csi-secrets-store-provider-aws"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    PROVIDER_POD=$(kubectl --namespace $NAMESPACE get pod -l app=csi-secrets-store-provider-aws -o jsonpath="{.items[0].metadata.name}")
    run kubectl --namespace $NAMESPACE get pod/$PROVIDER_POD
    assert_success
    progress_msg $CYAN "AWS provider installed successfully on x64 cluster"

    progress_msg $CYAN "Installing AWS provider on ARM cluster"
    # Install on ARM cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME_ARM | head -1)
    envsubst < $PROVIDER_YAML | kubectl apply -f -
    cmd="kubectl --namespace $NAMESPACE wait --for=condition=Ready --timeout=60s pod -l app=csi-secrets-store-provider-aws"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    PROVIDER_POD_ARM=$(kubectl --namespace $NAMESPACE get pod -l app=csi-secrets-store-provider-aws -o jsonpath="{.items[0].metadata.name}")
    run kubectl --namespace $NAMESPACE get pod/$PROVIDER_POD_ARM
    assert_success
    progress_msg $CYAN "AWS provider installed successfully on ARM cluster"
}

@test "secretproviderclasses crd is established" {
    progress_msg $CYAN "Verifying SecretProviderClasses CRD is established on both clusters"

    progress_msg $CYAN "Checking CRD on x64 cluster"
    # Check on x64 cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME | head -1)
    cmd="kubectl wait --namespace $NAMESPACE --for condition=established --timeout=60s crd/secretproviderclasses.secrets-store.csi.x-k8s.io"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    run kubectl get crd/secretproviderclasses.secrets-store.csi.x-k8s.io
    assert_success
    progress_msg $CYAN "CRD established successfully on x64 cluster"

    progress_msg $CYAN "Checking CRD on ARM cluster"
    # Check on ARM cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME_ARM | head -1)
    cmd="kubectl wait --namespace $NAMESPACE --for condition=established --timeout=60s crd/secretproviderclasses.secrets-store.csi.x-k8s.io"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    run kubectl get crd/secretproviderclasses.secrets-store.csi.x-k8s.io
    assert_success
    progress_msg $CYAN "CRD established successfully on ARM cluster"
}

@test "deploy aws secretproviderclass crd" {
    progress_msg $CYAN "Deploying SecretProviderClass configurations for both authentication methods"

    progress_msg $CYAN "Deploying IRSA SecretProviderClass on x64 cluster"
    # Deploy IRSA SecretProviderClass on x64 cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME | head -1)
    envsubst < BasicTestMountSPC-IRSA.yaml | kubectl --namespace $NAMESPACE apply -f -

    cmd="kubectl --namespace $NAMESPACE get secretproviderclasses.secrets-store.csi.x-k8s.io/basic-test-mount-spc-irsa -o yaml | grep aws"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    progress_msg $CYAN "Deploying Pod Identity SecretProviderClass on x64 cluster"
    # Deploy Pod Identity SecretProviderClass on x64 cluster
    envsubst < BasicTestMountSPC-PodIdentity.yaml | kubectl --namespace $NAMESPACE apply -f -

    cmd="kubectl --namespace $NAMESPACE get secretproviderclasses.secrets-store.csi.x-k8s.io/basic-test-mount-spc-pod-identity -o yaml | grep aws"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    progress_msg $CYAN "Deploying IRSA SecretProviderClass on ARM cluster"
    # Deploy IRSA SecretProviderClass on ARM cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME_ARM | head -1)
    envsubst < BasicTestMountSPC-IRSA.yaml | kubectl --namespace $NAMESPACE apply -f -

    cmd="kubectl --namespace $NAMESPACE get secretproviderclasses.secrets-store.csi.x-k8s.io/basic-test-mount-spc-irsa -o yaml | grep aws"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    progress_msg $CYAN "Deploying Pod Identity SecretProviderClass on ARM cluster"
    # Deploy Pod Identity SecretProviderClass on ARM cluster
    envsubst < BasicTestMountSPC-PodIdentity.yaml | kubectl --namespace $NAMESPACE apply -f -

    cmd="kubectl --namespace $NAMESPACE get secretproviderclasses.secrets-store.csi.x-k8s.io/basic-test-mount-spc-pod-identity -o yaml | grep aws"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    progress_msg $CYAN "All SecretProviderClass configurations deployed successfully"
}

@test "CSI inline volume test with pod portability" {
    progress_msg $CYAN "Testing CSI inline volume mounting with pod portability across all configurations"

    progress_msg $CYAN "Testing IRSA on x64 cluster"
    # Test IRSA on x64 cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME | head -1)
    kubectl --namespace $NAMESPACE apply -f BasicTestMount-IRSA.yaml
    cmd="kubectl --namespace $NAMESPACE wait --for=condition=Ready --timeout=60s pod/basic-test-mount-irsa"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    run kubectl --namespace $NAMESPACE get pod/$POD_NAME_IRSA
    assert_success

    progress_msg $CYAN "Testing Pod Identity on x64 cluster"
    # Test Pod Identity on x64 cluster
    kubectl --namespace $NAMESPACE apply -f BasicTestMount-PodIdentity.yaml
    cmd="kubectl --namespace $NAMESPACE wait --for=condition=Ready --timeout=60s pod/basic-test-mount-pod-identity"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    run kubectl --namespace $NAMESPACE get pod/$POD_NAME_POD_IDENTITY
    assert_success

    progress_msg $CYAN "Testing IRSA on ARM cluster"
    # Test IRSA on ARM cluster
    kubectl config use-context $(kubectl config get-contexts -o name | grep $CLUSTER_NAME_ARM | head -1)
    kubectl --namespace $NAMESPACE apply -f BasicTestMount-IRSA.yaml
    cmd="kubectl --namespace $NAMESPACE wait --for=condition=Ready --timeout=60s pod/basic-test-mount-irsa"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    run kubectl --namespace $NAMESPACE get pod/$POD_NAME_IRSA
    assert_success

    progress_msg $CYAN "Testing Pod Identity on ARM cluster"
    # Test Pod Identity on ARM cluster
    kubectl --namespace $NAMESPACE apply -f BasicTestMount-PodIdentity.yaml
    cmd="kubectl --namespace $NAMESPACE wait --for=condition=Ready --timeout=60s pod/basic-test-mount-pod-identity"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"

    run kubectl --namespace $NAMESPACE get pod/$POD_NAME_POD_IDENTITY
    assert_success

    progress_msg $CYAN "All pod portability tests completed successfully"
}

@test "CSI inline volume test with rotation - parameter store " {
    progress_msg $CYAN "Testing Parameter Store secret rotation across all configurations"
    run_test_on_both_clusters_and_auth_methods test_rotation_parameter_store
    progress_msg $CYAN "Parameter Store rotation tests completed successfully"
}

@test "CSI inline volume test with rotation - secrets manager " {
    progress_msg $CYAN "Testing Secrets Manager secret rotation across all configurations"
    run_test_on_both_clusters_and_auth_methods test_rotation_secrets_manager
    progress_msg $CYAN "Secrets Manager rotation tests completed successfully"
}

@test "CSI inline volume test with pod portability - read ssm parameters from pod" {
    progress_msg $CYAN "Testing SSM parameter reading from pods across all configurations"
    run_test_on_both_clusters_and_auth_methods test_read_ssm_parameters
    progress_msg $CYAN "SSM parameter reading tests completed successfully"
}

@test "CSI inline volume test with pod portability - read secrets manager secrets from pod" {
    progress_msg $CYAN "Testing Secrets Manager secret reading from pods across all configurations"
    run_test_on_both_clusters_and_auth_methods test_read_secrets_manager
    progress_msg $CYAN "Secrets Manager reading tests completed successfully"
}

@test "CSI inline volume test with pod portability - specify jmesPath for parameter store parameter with rotation" {
    progress_msg $CYAN "Testing JMESPath extraction for Parameter Store with rotation across all configurations"
    run_test_on_both_clusters_and_auth_methods test_jmes_parameter_store
    progress_msg $CYAN "Parameter Store JMESPath tests completed successfully"
}

@test "CSI inline volume test with pod portability - specify jmesPath for Secrets Manager secret with rotation" {
    progress_msg $CYAN "Testing JMESPath extraction for Secrets Manager with rotation across all configurations"
    run_test_on_both_clusters_and_auth_methods test_jmes_secrets_manager
    progress_msg $CYAN "Secrets Manager JMESPath tests completed successfully"
}

@test "Sync with Kubernetes Secret" {
    progress_msg $CYAN "Testing Kubernetes Secret synchronization across all configurations"
    run_test_on_both_clusters_and_auth_methods test_sync_kubernetes_secret
    progress_msg $CYAN "Kubernetes Secret sync tests completed successfully"
}

@test "Sync with Kubernetes Secret - Delete deployment. Secret should also be deleted" {
    progress_msg $CYAN "Testing Kubernetes Secret cleanup on deployment deletion across all configurations"
    run_test_on_both_clusters_and_auth_methods test_sync_kubernetes_secret_delete
    progress_msg $CYAN "Kubernetes Secret cleanup tests completed successfully"
}
