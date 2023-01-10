# csi-secrets-store-provider-aws

[Project repository](https://github.com/aws/secrets-store-csi-driver-provider-aws)

The AWS provider for the [Secrets Store CSI Driver](https://github.com/kubernetes-sigs/secrets-store-csi-driver) allows you to make secrets stored in Secrets Manager and parameters stored in Parameter Store appear as files mounted in Kubernetes pods.

### Prerequisites

* Amazon Elastic Kubernetes Service (EKS) 1.17+ using ECS (Fargate is not supported **[^1]**)
* [Secrets Store CSI driver installed](https://secrets-store-csi-driver.sigs.k8s.io/getting-started/installation.html):
    ```shell
    helm repo add secrets-store-csi-driver https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
    helm install -n kube-system csi-secrets-store secrets-store-csi-driver/secrets-store-csi-driver
    ```
  **Note** that older versions of the driver may require the ```--set grpcSupportedProviders="aws"``` flag on the install step.
* IAM Roles for Service Accounts ([IRSA](https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html)) as described in the usage section below.

[^1]: The CSI Secret Store driver runs as a DaemonSet, and as described in the [AWS documentation](https://docs.aws.amazon.com/eks/latest/userguide/fargate.html#fargate-considerations), DaemonSet is not supported on Fargate. 

### Installing the Chart

Using Helm:
```shell
helm repo add aws-secrets-manager https://aws.github.io/secrets-store-csi-driver-provider-aws
helm install -n kube-system secrets-provider-aws aws-secrets-manager/secrets-store-csi-driver-provider-aws
```

Using YAML:
```shell
kubectl apply -n kube-system -f https://raw.githubusercontent.com/aws/secrets-store-csi-driver-provider-aws/main/deployment/aws-provider-installer.yaml
```

### Create the access policy

Follow the [Usage](https://github.com/aws/secrets-store-csi-driver-provider-aws#usage) guide.

### Configuration

The following table lists the configurable parameters of the csi-secrets-store-provider-aws chart and their default values.

> Refer to [doc](https://github.com/kubernetes-sigs/secrets-store-csi-driver/tree/main/charts/secrets-store-csi-driver/README.md) for configurable parameters of the secrets-store-csi-driver chart.

| Parameter | Description | Default |
| --- | --- | --- |
| `nameOverride` | String to override the name template with a string | `""` |
| `fullnameOverride` | String to override the fullname template with a string | `""` |
| `image.repository` | Image repository | `public.ecr.aws/aws-secrets-manager/secrets-store-csi-driver-provider-aws` |
| `image.pullPolicy` | Image pull policy | `IfNotPresent` |
| `image.tag`| Image tag | `1.0.r2-6-gee95299-2022.04.14.21.07` (Updates frequently) |
| `nodeSelector` | Node Selector for the daemonset on nodes | `{}` |
| `tolerations` | Tolerations for the daemonset on nodes  | `[]` |
| `port` | Liveness and readyness tcp probe port  | `8989` |
| `securityContext.privileged` | Privileged security context | `false`
| `resources`| Resource limit for provider pods on nodes | `requests.cpu: 50m`<br>`requests.memory: 100Mi`<br>`limits.cpu: 50m`<br>`limits.memory: 100Mi` |
| `podLabels`| Additional pod labels | `{}` |
| `podAnnotations` | Additional pod annotations| `{}` |
| `updateStrategy` | Configure a custom update strategy for the daemonset on nodes | `RollingUpdate`|
| `rbac.install` | Install default service account | true |
