# AWS Secrets Manager and Config Provider for Secret Store CSI Driver

![badge](https://github.com/aws/secrets-store-csi-driver-provider-aws/actions/workflows/go.yml/badge.svg)
[![codecov](https://codecov.io/gh/aws/secrets-store-csi-driver-provider-aws/branch/main/graph/badge.svg?token=S7ZDTT1F8K)](https://codecov.io/gh/aws/secrets-store-csi-driver-provider-aws)

AWS offers two services to manage secrets and parameters conveniently in your code. AWS [Secrets Manager](https://aws.amazon.com/secrets-manager/) allows you to easily rotate, manage, and retrieve database credentials, API keys, certificates, and other secrets throughout their lifecycle. AWS [Systems Manager Parameter Store](https://docs.aws.amazon.com/systems-manager/latest/userguide/systems-manager-parameter-store.html) provides hierarchical storage for configuration data. The AWS provider for the [Secrets Store CSI Driver](https://github.com/kubernetes-sigs/secrets-store-csi-driver) allows you to make secrets stored in Secrets Manager and parameters stored in Parameter Store appear as files mounted in Kubernetes pods.

## Installation

### Requirements
* Amazon Elastic Kubernetes Service (EKS) 1.17+ running an EC2 node group (Fargate node groups are not supported **[^1]**). If using EKS Pod Identity feature, EKS 1.24+ is required. 
* [Secrets Store CSI driver installed](https://secrets-store-csi-driver.sigs.k8s.io/getting-started/installation.html):
    ```shell
    helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
    helm install -n kube-system csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver
    ```
  **Note** that older versions of the driver may require the ```--set grpcSupportedProviders="aws"``` flag on the install step.
* IAM Roles for Service Accounts ([IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)) or [EKS Pod Identity](https://docs.aws.amazon.com/eks/latest/userguide/pod-identities.html) as described in the usage section below.

[^1]: The CSI Secret Store driver runs as a DaemonSet, and as described in the [AWS documentation](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html#fargate-considerations), DaemonSet is not supported on Fargate.

### Installing the AWS Provider and Config Provider (ASCP)

#### Option 1: Using helm

```shell
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws
helm install -n kube-system secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws
```

#### Option 2: Using kubectl

```shell
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
```

## Usage

Set the region name and name of your cluster to use in the bash commands that follow:
```bash
REGION=<REGION>
CLUSTERNAME=<CLUSTERNAME>
```
Where **&lt;REGION&gt;** is the region in which your Kubernetes cluster is running and **&lt;CLUSTERNAME&gt;** is the name of your cluster.

Create a test secret:
```shell
aws --region "$REGION" secretsmanager  create-secret --name MySecret --secret-string '{"username":"memeuser", "password":"hunter2"}'
```

Create an access policy for the pod scoped down to just the secrets it should have and save the policy ARN in a shell variable:
```shell
POLICY_ARN=$(aws --region "$REGION" --query Policy.Arn --output text iam create-policy --policy-name nginx-deployment-policy --policy-document '{
    "Version": "2012-10-17",
    "Statement": [ {
        "Effect": "Allow",
        "Action": ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"],
        "Resource": ["arn:*:secretsmanager:*:*:secret:MySecret-??????"]
    } ]
}')
```
**Note**, when using SSM parameters the permission "ssm:GetParameters" is needed in the policy. To simplify this example we use wild card matches above but you could lock this down further using the full ARN from the output of create-secret above.

#### Option 1: Using IAM Roles For Service Accounts (IRSA)

1. Create the IAM OIDC provider for the cluster if you have not already done so:
```shell
eksctl utils associate-iam-oidc-provider --region="$REGION" --cluster="$CLUSTERNAME" --approve # Only run this once
```
2. Next, create the service account to be used by the pod and associate the above IAM policy with that service account. For this example we use *nginx-irsa-deployment-sa* for the service account name:
```shell
eksctl create iamserviceaccount --name nginx-irsa-deployment-sa --region="$REGION" --cluster "$CLUSTERNAME" --attach-policy-arn "$POLICY_ARN" --approve --override-existing-serviceaccounts
```
For a private cluster, ensure that the VPC the cluster is in has an AWS STS endpoint. For more information, see [Interface VPC endpoints](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_interface_vpc_endpoints.html) in the AWS IAM User Guide.

3. Create the SecretProviderClass which tells the AWS provider which secrets are to be mounted in the pod. The ExampleSecretProviderClass-IRSA.yaml in the [examples](./examples) directory will mount "MySecret" created above:
```shell
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/examples/ExampleSecretProviderClass-IRSA.yaml
```
4. Finally, we can deploy our pod. The ExampleDeployment-IRSA.yaml in the examples directory contains a sample nginx deployment that mounts the secrets under /mnt/secrets-store in the pod:
```shell
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/examples/ExampleDeployment-IRSA.yaml
```

To verify the secret has been mounted properly, See the example below:

```shell
kubectl exec -it $(kubectl get pods | awk '/nginx-irsa-deployment/{print $1}' | head -1) -- cat /mnt/secrets-store/MySecret; echo
```

#### Option 2: Using EKS Pod Identity
*Note: EKS Pod Identity option is only supported for EKS in the Cloud. It's not supported for [Amazon EKS Anywhere](https://aws.amazon.com/eks/eks-anywhere/), [Red Hat Openshift Service on AWS (ROSA)](https://aws.amazon.com/rosa/) and self-managed Kubernetes clusters on Amazon Elastic Compute Cloud (Amazon EC2) instances.*
1. Install Amazon EKS Pod Identity Agent Add-on on the cluster.
```shell
eksctl create addon --name eks-pod-identity-agent --cluster "$CLUSTERNAME" --region "$REGION"
```
2. Create an IAM role that can be assumed by the Amazon EKS service principal for Pod Identity and attach the above IAM policy to grant access to the test secret. 
```shell
ROLE_ARN=$(aws --region "$REGION" --query Role.Arn --output text iam create-role --role-name nginx-deployment-role --assume-role-policy-document '{
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
```
```shell
aws iam attach-role-policy \
    --role-name nginx-deployment-role \
    --policy-arn $POLICY_ARN
```
3. Next create the service account to be used by the pod and associate the service account with the IAM role created above. For this example we use *nginx-pod-identity-deployment-sa* for the service account name:
```shell
eksctl create podidentityassociation \
    --cluster "$CLUSTERNAME" \
    --namespace default \
    --region "$REGION" \
    --service-account-name nginx-pod-identity-deployment-sa \
    --role-arn $ROLE_ARN \
    --create-service-account true
```
4. Now create the SecretProviderClass which tells the AWS provider which secrets are to be mounted in the pod. The ExampleSecretProviderClass-PodIdentity.yaml in the [examples](./examples) directory will mount "MySecret" created above:
```shell
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/examples/ExampleSecretProviderClass-PodIdentity.yaml
```
5. Finally, we can deploy our pod. The ExampleDeployment-PodIdentity.yaml in the examples directory contains a sample nginx deployment that mounts the secrets under /mnt/secrets-store in the pod:
```shell
kubectl apply -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/examples/ExampleDeployment-PodIdentity.yaml
```

To verify the secret has been mounted properly, See the example below:

```shell
kubectl exec -it $(kubectl get pods | awk '/nginx-pod-identity-deployment/{print $1}' | head -1) -- cat /mnt/secrets-store/MySecret; echo
```

### Troubleshooting
Most errors can be viewed by describing the pod deployment. For the deployment, find the pod names using get pods (use -n **&lt;NAMESPACE&gt;** if you are not using the default namespace):
```shell
kubectl get pods
```
Then describe the pod (substitute the pod ID from above for **&lt;PODID&gt;**, as before use -n if you are not using the default namespace):
```shell
kubectl describe pod/<PODID>
```
Additional information may be available in the provider logs:
```shell
kubectl -n kube-system get pods
kubectl -n kube-system logs pod/<PODID>
```
Where **&lt;PODID&gt;** in this case is the id of the *csi-secrets-store-provider-aws* pod.

### SecretProviderClass options
The SecretProviderClass has the following format:
```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: <NAME>
spec:
  provider: aws
  parameters:
```
The parameters section contains the details of the mount request and contain one of the three fields:
* objects: This is a string containing a YAML declaration (described below) of the secrets to be mounted. This is most easily written using a YAML multi-line string or pipe character. For example:
    ```yaml
      parameters:
        objects: |
            - objectName: "MySecret"
              objectType: "secretsmanager"
    ```
* region: An optional field to specify the AWS region to use when retrieving secrets from Secrets Manager or Parameter Store. If this field is missing, the provider will lookup the region from the `topology.kubernetes.io/region` label on the node. This lookup adds overhead to mount requests so clusters using large numbers of pods will benefit from providing the region here.
* failoverRegion: An optional field to specify a secondary AWS region to use when retrieving secrets. See the Automated Failover Regions section in this readme for more information.
* pathTranslation: An optional field to specify a substitution character to use when the path separator character (slash on Linux) is used in the file name. If a Secret or parameter name contains the path separator failures will occur when the provider tries to create a mounted file using the name. When not specified the underscore character is used, thus My/Path/Secret will be mounted as My_Path_Secret. This pathTranslation value can either be the string "False" or a single character string. When set to "False", no character substitution is performed.
* usePodIdentity: An optional field that determines the authentication approach. When not specified, it defaults to using IAM Roles for Service Accounts (IRSA). 
  - To use EKS Pod Identity, use any of these values: "true", "True", "TRUE", "t", "T".
  - To explicitly use IRSA, set to any of these values: "false", "False", "FALSE", "f", or "F".
* preferredAddressType: An optional field that specifies the preferred IP address type for Pod Identity Agent endpoint communication. The field is only applicable when using EKS Pod Identity feature and will be ignored when using IAM Roles for Service Accounts.Values are case-insensitive. Valid values are:
  - "ipv4", "IPv4", or "IPV4" - Force the use of Pod Identity Agent IPv4 endpoint
  - "ipv6", "IPv6", or "IPV6" - Force the use of Pod Identity Agent IPv6 endpoint
  - not specified - Use auto endpoint selection, trying IPv4 endpoint first and falling back to IPv6 endpoint if IPv4 fails

The primary objects field of the SecretProviderClass can contain the following sub-fields:
* objectName: This field is required. It specifies the name of the secret or parameter to be fetched. For Secrets Manager this is the [SecretId](https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetSecretValue.html#API_GetSecretValue_RequestParameters) parameter and can be either the friendly name or full ARN of the secret. For SSM Parameter Store, this is the [Name](https://docs.aws.amazon.com/systems-manager/latest/APIReference/API_GetParameter.html#API_GetParameter_RequestParameters) of the parameter and can be either the name or full ARN of the parameter.
* objectType: This field is optional when using a Secrets Manager ARN for objectName, otherwise it is required. This field can be either "secretsmanager" or "ssmparameter".
* objectAlias: This optional field specifies the file name under which the secret will be mounted. When not specified the file name defaults to objectName.
* filePermission: This optional field expects a 4 digit string which specifies the file permission for the secret that will be mounted. When not specified this will default to "0644" permisions. Ensure the 4 digit string is a valid octal file permission.
* objectVersion: This field is optional, and generally not recommended since updates to the secret require updating this field. For Secrets Manager this is the [VersionId](https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetSecretValue.html#API_GetSecretValue_RequestParameters). For SSM Parameter Store, this is the optional [version number](https://docs.aws.amazon.com/systems-manager/latest/userguide/sysman-paramstore-versions.html#reference-parameter-version).
* objectVersionLabel: This optional field specifies the alias used for the version. Most applications should not use this field since the most recent version of the secret is used by default. For Secrets Manager this is the [VersionStage](https://docs.aws.amazon.com/secretsmanager/latest/apireference/API_GetSecretValue.html#API_GetSecretValue_RequestParameters). For SSM Parameter Store this is the optional [Parameter Label](https://docs.amazonaws.cn/en_us/systems-manager/latest/userguide/sysman-paramstore-labels.html).

* failoverObject: An optional field when using the failoverRegion feature. See the Automated Failover Regions section in this readme for more information. The failover object can contain the following sub-fields:
  * objectName: This field is required if failoverObject is present. Specifies the name of the secret or parameter to be fetched from the failover region. See the primary objectName field for more information.
  * objectVersion: This field is optional and defines the objectVersion for the failover region.  If specified, it must match the primary region's objectVersion. See the primary objectVersion field for more information.
  * objectVersionLabel: This optional field specifies the alias used for the version of the failoverObject. See the primary objectVersionLabel field for more information. 

* jmesPath: This optional field specifies the specific key-value pairs to extract from a JSON-formatted secret. You can use this field to mount key-value pairs from a properly formatted secret value as individual secrets. For example: Consider a secret "MySecret" with JSON content as follows:

    ```shell
        {
            "username": "testuser"
            "password": "testpassword"
        }
     ```
  To mount the username and password key pairs of this secret as individual secrets, use the jmesPath field as follows:

  ```yaml:
        objects: |
            - objectName: "MySecret"
              objectType: "secretsmanager"
              jmesPath:
                  - path: "username"
                    objectAlias: "MySecretUsername"
                  - path: "password"
                    objectAlias: "MySecretPassword"
  ```
  If either the 'path' or the 'objectAlias' fields contain a hyphen, then they must be escaped with a single quote:
  
  ```
  - path: '"hyphenated-path"'
    objectAlias: '"hyphenated-alias"'
  ```
  
  If you use the jmesPath field,  you must provide the following two sub-fields:
  * path: This required field is the [JMES path](https://jmespath.org/specification.html) to use for retrieval
  * objectAlias: This required field specifies the file name under which the key-value pair secret will be mounted. 

  You may pass an additional sub-field to specify the file permission:
  * filePermission: This optional field expects a 4 digit string which specifies the file permission for the secret that will be mounted. When not specified this will default to the parent object's file permission.

## Additional Considerations

### Rotation
When using the optional alpha [rotation reconciler](https://secrets-store-csi-driver.sigs.k8s.io/topics/secret-auto-rotation.html) feature of the Secrets Store CSI driver the driver will periodically remount the secrets in the SecretProviderClass. This will cause additional API calls which results in additional charges. Applications should use a reasonable poll interval that works with their rotation strategy. A one hour poll interval is recommended as a default to reduce excessive API costs.

Anyone wishing to test out the rotation reconciler feature can enable it using helm:
```bash
helm upgrade -n kube-system csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver --set enableSecretRotation=true --set rotationPollInterval=3600s
```

### Automated Failover Regions
In order to provide availability during connectivity outages or for disaster recovery configurations, this provider supports an automated failover feature to fetch secrets or parameters from a secondary region. To define an automated failover region, define the failoverRegion in the SecretProviderClass.yaml file:
```yaml
spec:
  provider: aws
  parameters:
    region: us-east-1
    failoverRegion: us-east-2
```

When the failoverRegion is defined, the driver will attempt to get the secret value from both regions.
* If both regions successfully retrieve the secret value, then the mount will contain the secret value of the secret in the primary region.
* If one region returns a non-client error (code 5XX), and the other region succeeds, then the mount will contain the secret value of the non-failing region.
* If either region returns a client error (code 4XX), then the mount will fail, and the cause of the error must be resolved before the mount will succeed.

 It is possible to use different secrets or parameters between the primary and failover regions.  This example will use different ARNs depending on which region it is pulling from:
 ```yaml
- objectName: "arn:aws:secretsmanager:us-east-1:123456789012:secret:PrimarySecret-12345"
  failoverObject: 
    objectName: "arn:aws:secretsmanager:us-east-2:123456789012:secret:FailoverSecret-12345" 
  objectAlias: testArn
```
If 'failoverObject' is defined, then objectAlias is required.

### Using EKS Pod Identity to Access Cross-Account AWS Resources

EKS Pod Identity [CreatePodIdentityAssociation](https://docs.aws.amazon.com/eks/latest/APIReference/API_CreatePodIdentityAssociation.html) requires the IAM role to reside in the same AWS account as the EKS cluster. 

To mount AWS Secrets Manager secrets from a different AWS account than your EKS cluster, follow [cross-account access](https://docs.aws.amazon.com/secretsmanager/latest/userguide/auth-and-access_examples_cross.html) to set up resource policy for the secret, key policy for the KMS key, and IAM role used in Pod Identity association.
Fetching cross-account parameters from SSM Parameter Store is only supported for parameters in the advanced parameter tier. See [Working with Shared Parameters](https://docs.aws.amazon.com/systems-manager/latest/userguide/parameter-store-shared-parameters.html) for details. 

### Private Builds
You can pull down this git repository and build and install this plugin into your account's [AWS ECR](https://aws.amazon.com/ecr/) registry using the following steps. First clone the repository:
```shell
git clone https://github.com/aws/secrets-store-csi-driver-provider-aws
cd secrets-store-csi-driver-provider-aws
```
Next, set your region and repository name in bash shell variables to be used later:
```bash
export REGION=<REGION>
export PRIVREPO=<ACCOUNT>.dkr.ecr.$REGION.amazonaws.com/secrets-store-csi-driver-provider-aws
```
Where **&lt;REGION&gt;** is the AWS region in which your Kubernetes cluster is running, and **&lt;ACCOUNT&gt;** is your AWS account Id. Next create your ECR repository if you have not already done so:
```bash
aws --region $REGION ecr create-repository --repository-name secrets-store-csi-driver-provider-aws # Only do this once
```
Now run make to build the plugin and push it into your account's repo:
```
make
```
Once the image is in your repo you can install it into your cluster from your repo rather than the public repo:
```bash
envsubst < deployment/private-installer.yaml | kubectl apply -f -
```

### Configure the Underlying Secrets Manager Client to Use FIPS Endpoint

If you use Helm chart to install the provider, append the `--set useFipsEndpoint=true` flag on the install step. Your install command would be something like

```shell
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws
helm install -n kube-system secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws --set useFipsEndpoint=true
```

### Client-Side Rate-Limitting to Kubernetes API server

To mount each secret on each pod, the AWS CSI provider lookups the region of the pod and the role ARN associated with the service account by calling the Kubernetes APIs. You can increase the value of qps and burst if you notice the provider is throttled by client-side limit to the API server.

If you use Helm chart to install the provider, append the `--set-json 'k8sThrottlingParams={"qps": "<custom qps>", "burst": "<custom qps>"}'` flag in the install step.

### Security Considerations

The AWS Secrets Manager and Config Provider provides compatibility for legacy applications that access secrets as mounted files in the pod. Security conscious applications should use the native AWS APIs to fetch secrets and optionally cache them in memory rather than storing them in the file system.

## Security

See [CONTRIBUTING](CONTRIBUTING.md#security-issue-notifications) for more information.

## License

This project is licensed under the Apache-2.0 License.
