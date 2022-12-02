#!/usr/bin/env bats
 
load helpers 
 
WAIT_TIME=120
SLEEP_TIME=1
PROVIDER_YAML=../deployment/private-installer.yaml
NAMESPACE=kube-system
CLUSTER_NAME=integ-cluster
POD_NAME=basic-test-mount
export REGION=us-west-2
export FAILOVER_REGION=us-east-2
export ACCOUNT_NUMBER=$(aws --region $REGION  sts get-caller-identity --query Account --output text)

if [[ -z "${PRIVREPO}" ]]; then
    echo "Error: PRIVREPO is not specified" >&2
    return 1
fi

if [[ -z "${NODE_TYPE}" ]]; then
    NODE_TYPE=m5.large
fi

setup_file() {
    #Create and initialize cluster 
    eksctl create cluster \
       --name $CLUSTER_NAME \
       --node-type $NODE_TYPE \
       --nodes 3 \
       --region $REGION
 
   eksctl utils associate-iam-oidc-provider --name $CLUSTER_NAME --approve --region $REGION
    
   eksctl create iamserviceaccount \
       --name basic-test-mount-sa \
       --namespace $NAMESPACE \
       --cluster $CLUSTER_NAME \
       --attach-policy-arn arn:aws:iam::aws:policy/AmazonSSMReadOnlyAccess \
       --attach-policy-arn arn:aws:iam::aws:policy/SecretsManagerReadWrite \
       --override-existing-serviceaccounts \
       --approve \
       --region $REGION    
   
   #Install csi secret driver
   helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
   helm --namespace=$NAMESPACE install csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver --set enableSecretRotation=true --set rotationPollInterval=15s --set syncSecret.enabled=true
 
   #Create test secrets
   aws secretsmanager create-secret --name SecretsManagerTest1 --secret-string SecretsManagerTest1Value --region $REGION
   aws secretsmanager create-secret --name SecretsManagerTest2 --secret-string SecretsManagerTest2Value --region $REGION
   aws secretsmanager create-secret --name SecretsManagerSync --secret-string SecretUser --region $REGION
   aws secretsmanager create-secret --name SecretsManagerFailOverRegionTest --secret-string SecretsManagerTest3Value --region $FAILOVER_REGION
   aws secretsmanager create-secret --name SMBackupSecret --secret-string SMBackupSecretValue --region $FAILOVER_REGION

   aws ssm put-parameter --name ParameterStoreTest1 --value ParameterStoreTest1Value --type SecureString --region $REGION
   aws ssm put-parameter --name ParameterStoreTestWithLongName --value ParameterStoreTest2Value --type SecureString --region $REGION
   aws ssm put-parameter --name ParameterStoreFailOverRegionTest --value ParameterStoreTest3Value --type SecureString --region $FAILOVER_REGION

   aws ssm put-parameter --name ParameterStoreRotationTest --value BeforeRotation --type SecureString --region $REGION
   aws secretsmanager create-secret --name SecretsManagerRotationTest --secret-string BeforeRotation --region $REGION

   aws ssm put-parameter --name ParamFailOverRegionRotationTest --value BeforeRotation --type SecureString --region $FAILOVER_REGION
   aws secretsmanager create-secret --name SMFailOverRegionRotationTest --secret-string BeforeRotation --region $FAILOVER_REGION

   aws secretsmanager create-secret --name secretsManagerJson  --secret-string '{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}' --region $REGION
   aws ssm put-parameter --name jsonSsm --value '{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}' --type SecureString --region $REGION
}
 
teardown_file() { 

    eksctl delete cluster \
        --name $CLUSTER_NAME \
        --region $REGION
 
    aws secretsmanager delete-secret --secret-id SecretsManagerTest1 --force-delete-without-recovery --region $REGION
    aws secretsmanager delete-secret --secret-id SecretsManagerTest2 --force-delete-without-recovery --region $REGION
    aws secretsmanager delete-secret --secret-id SecretsManagerSync --force-delete-without-recovery --region $REGION
    aws secretsmanager delete-secret --secret-id SecretsManagerFailOverRegionTest --force-delete-without-recovery --region $FAILOVER_REGION
    aws secretsmanager delete-secret --secret-id SMBackupSecret --force-delete-without-recovery --region $FAILOVER_REGION

    aws ssm delete-parameter --name ParameterStoreTest1 --region $REGION
    aws ssm delete-parameter --name ParameterStoreTestWithLongName --region $REGION 
    aws ssm delete-parameter --name ParameterStoreFailOverRegionTest --region $FAILOVER_REGION

    aws ssm delete-parameter --name ParameterStoreRotationTest --region $REGION
    aws secretsmanager delete-secret --secret-id SecretsManagerRotationTest --force-delete-without-recovery --region $REGION

    aws ssm delete-parameter --name SSMFailOverRegionRotationTest --region $FAILOVER_REGION
    aws secretsmanager delete-secret --secret-id SMFailOverRegionRotationTest --force-delete-without-recovery --region $FAILOVER_REGION

    aws ssm delete-parameter --name jsonSsm --region $REGION
    aws secretsmanager delete-secret --secret-id secretsManagerJson --force-delete-without-recovery --region $REGION
}

validate_jsme_mount() {
    result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/$USERNAME_ALIAS)
    [[ "${result//$'\r'}" == $USERNAME ]]

    result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/$PASSWORD_ALIAS)
    [[ "${result//$'\r'}" == $PASSWORD ]]

    result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/$SECRET_FILE_NAME)
    [[ "${result//$'\r'}" == $SECRET_FILE_CONTENT ]]

    run kubectl get secret --namespace $NAMESPACE $K8_SECRET_NAME
    [ "$status" -eq 0 ]

    result=$(kubectl --namespace=$NAMESPACE get secret $K8_SECRET_NAME -o jsonpath="{.data.username}" | base64 -d)
    [[ "$result" == $USERNAME ]]
    
    result=$(kubectl --namespace=$NAMESPACE get secret $K8_SECRET_NAME -o jsonpath="{.data.password}" | base64 -d)
    [[ "$result" == $PASSWORD ]]
}

@test "Install aws provider" {
    envsubst < $PROVIDER_YAML | kubectl apply -f - 
    cmd="kubectl --namespace $NAMESPACE wait --for=condition=Ready --timeout=60s pod -l app=csi-secrets-store-provider-aws"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"
 
    PROVIDER_POD=$(kubectl --namespace $NAMESPACE get pod -l app=csi-secrets-store-provider-aws -o jsonpath="{.items[0].metadata.name}")	
    run kubectl --namespace $NAMESPACE get pod/$PROVIDER_POD
    assert_success
}

@test "secretproviderclasses crd is established" {
    cmd="kubectl wait --namespace $NAMESPACE --for condition=established --timeout=60s crd/secretproviderclasses.secrets-store.csi.x-k8s.io"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"
 
    run kubectl get crd/secretproviderclasses.secrets-store.csi.x-k8s.io
    assert_success
}
 
@test "deploy aws secretproviderclass crd" {
    envsubst < BasicTestMountSPC.yaml | kubectl --namespace $NAMESPACE apply -f -
 
    cmd="kubectl --namespace $NAMESPACE get secretproviderclasses.secrets-store.csi.x-k8s.io/basic-test-mount-spc -o yaml | grep aws"
    wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"
}
 
@test "CSI inline volume test with pod portability" {
   kubectl --namespace $NAMESPACE  apply -f BasicTestMount.yaml
   cmd="kubectl --namespace $NAMESPACE  wait --for=condition=Ready --timeout=60s pod/basic-test-mount"
   wait_for_process $WAIT_TIME $SLEEP_TIME "$cmd"
 
   run kubectl --namespace $NAMESPACE  get pod/$POD_NAME
   assert_success
}

@test "CSI inline  volume test with rotation - parameter store " {
   result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParameterStoreRotationTest)
   [[ "${result//$'\r'}" == "BeforeRotation" ]]
 
   aws ssm put-parameter --name ParameterStoreRotationTest --value AfterRotation --type SecureString --overwrite --region $REGION
   sleep 20
   result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParameterStoreRotationTest)
   [[ "${result//$'\r'}" == "AfterRotation" ]]
}
 
 @test "CSI inline volume test with rotation - failover secret - parameter store " {
   result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParamFailOverRegionRotationTest)
   [[ "${result//$'\r'}" == "BeforeRotation" ]]
 
   aws ssm put-parameter --name ParamFailOverRegionRotationTest --value AfterRotation --type SecureString --overwrite --region $FAILOVER_REGION
   sleep 20
   result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParamFailOverRegionRotationTest)
   [[ "${result//$'\r'}" == "AfterRotation" ]]
}

@test "CSI inline volume test with rotation - secrets manager " {
   result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SecretsManagerRotationTest)
   [[ "${result//$'\r'}" == "BeforeRotation" ]]
  
   aws secretsmanager put-secret-value --secret-id SecretsManagerRotationTest --secret-string AfterRotation --region $REGION
   sleep 20
   result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SecretsManagerRotationTest)
   [[ "${result//$'\r'}" == "AfterRotation" ]]
}

@test "CSI inline volume test with rotation - failover secret  - secrets manager " {
   fallback_secret_result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SMFailOverRegionRotationTest)
   [[ "${result//$'\r'}" == "BeforeRotation" ]]
  
   aws secretsmanager put-secret-value --secret-id SMFailOverRegionRotationTest --secret-string AfterRotation --region $FAILOVER_REGION
   sleep 20
   result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SMFailOverRegionRotationTest)
   [[ "${result//$'\r'}" == "AfterRotation" ]]
}

@test "CSI inline volume test with pod portability - read ssm parameters from pod" {
   result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParameterStoreTest1)
   [[ "${result//$'\r'}" == "ParameterStoreTest1Value" ]]
 
   result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParameterStoreTest2)
   [[ "${result//$'\r'}" == "ParameterStoreTest2Value" ]]
}

@test "CSI inline volume test with pod portability - read failover ssm parameters from pod" {
   result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/ParameterStoreFailOverRegionTest)
   [[ "${result//$'\r'}" == "ParameterStoreTest3Value" ]]
}
 

@test "CSI inline volume test with pod portability - read secrets manager secrets from pod" {
    result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SecretsManagerTest1)
    [[ "${result//$'\r'}" == "SecretsManagerTest1Value" ]]          
   
    result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SecretsManagerTest2)
    [[ "${result//$'\r'}" == "SecretsManagerTest2Value" ]]       
}

@test "CSI inline volume test with pod portability - read secrets manager failover secrets from pod" {
    result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/SecretsManagerFailOverRegionTest)
    [[ "${result//$'\r'}" == "SecretsManagerTest3Value" ]]    

    result=$(kubectl --namespace $NAMESPACE exec $POD_NAME -- cat /mnt/secrets-store/smFailOverSecret)
    [[ "${result//$'\r'}" == "SMBackupSecretValue" ]]        
}

@test "CSI inline volume test with pod portability - specify jsmePath for parameter store parameter with rotation" {
    JSON_CONTENT='{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}'
   
    USERNAME_ALIAS=ssmUsername USERNAME=ParameterStoreUser PASSWORD_ALIAS=ssmPassword PASSWORD=PasswordForParameterStore\
    SECRET_FILE_NAME=jsonSsm SECRET_FILE_CONTENT=$JSON_CONTENT K8_SECRET_NAME=json-ssm  validate_jsme_mount

    UPDATED_JSON_CONTENT='{"username": "ParameterStoreUserUpdated", "password": "PasswordForParameterStoreUpdated"}'
    aws ssm put-parameter --name jsonSsm --value "$UPDATED_JSON_CONTENT" --type SecureString --overwrite --region $REGION
    
    sleep 20
    USERNAME_ALIAS=ssmUsername USERNAME=ParameterStoreUserUpdated PASSWORD_ALIAS=ssmPassword PASSWORD=PasswordForParameterStoreUpdated\
    SECRET_FILE_NAME=jsonSsm SECRET_FILE_CONTENT=$UPDATED_JSON_CONTENT K8_SECRET_NAME=json-ssm  validate_jsme_mount
}

@test "CSI inline volume test with pod portability - specify jsmePath for Secrets Manager secret with rotation" {

    JSON_CONTENT='{"username": "SecretsManagerUser", "password": "PasswordForSecretsManager"}'

    USERNAME_ALIAS=secretsManagerUsername USERNAME=SecretsManagerUser PASSWORD_ALIAS=secretsManagerPassword \
    PASSWORD=PasswordForSecretsManager SECRET_FILE_NAME=secretsManagerJson SECRET_FILE_CONTENT=$JSON_CONTENT 
    K8_SECRET_NAME=secrets-manager-json validate_jsme_mount     

    UPDATED_JSON_CONTENT='{"username": "SecretsManagerUserUpdated", "password": "PasswordForSecretsManagerUpdated"}'
    aws secretsmanager put-secret-value --secret-id secretsManagerJson --secret-string "$UPDATED_JSON_CONTENT" --region $REGION

    sleep 20
    USERNAME_ALIAS=secretsManagerUsername USERNAME=SecretsManagerUserUpdated PASSWORD_ALIAS=secretsManagerPassword \
    PASSWORD=PasswordForSecretsManagerUpdated SECRET_FILE_NAME=secretsManagerJson SECRET_FILE_CONTENT=$UPDATED_JSON_CONTENT
    K8_SECRET_NAME=secrets-manager-json validate_jsme_mount
}

@test "Sync with Kubernetes Secret" {
    run kubectl get secret --namespace $NAMESPACE  secret
    [ "$status" -eq 0 ]
 
    result=$(kubectl --namespace=$NAMESPACE get secret secret -o jsonpath="{.data.username}" | base64 -d)
    [[ "$result" == "SecretUser" ]]
}

@test "Sync with Kubernetes Secret - Delete deployment. Secret should also be deleted" {
    run kubectl --namespace $NAMESPACE  delete -f BasicTestMount.yaml
    assert_success
 
    run wait_for_process $WAIT_TIME $SLEEP_TIME "check_secret_deleted secret $NAMESPACE"
    assert_success
}
