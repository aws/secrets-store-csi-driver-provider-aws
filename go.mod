module github.com/aws/secrets-store-csi-driver-provider-aws

go 1.16

require (
	github.com/aws/aws-sdk-go v1.38.32
	google.golang.org/grpc v1.37.0
	k8s.io/api v0.20.2
	k8s.io/apimachinery v0.20.2
	k8s.io/client-go v0.20.2
	k8s.io/klog/v2 v2.8.0
	sigs.k8s.io/secrets-store-csi-driver v0.0.20
	sigs.k8s.io/yaml v1.2.0
)
