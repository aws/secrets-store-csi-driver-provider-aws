module github.com/aws/secrets-store-csi-driver-provider-aws

go 1.15

require (
	github.com/aws/aws-sdk-go v1.37.0
	github.com/jmespath/go-jmespath v0.4.0
	google.golang.org/grpc v1.35.0
	k8s.io/api v0.20.2
	k8s.io/apimachinery v0.20.2
	k8s.io/client-go v0.20.2
	k8s.io/klog/v2 v2.60.1
	sigs.k8s.io/secrets-store-csi-driver v0.0.22
	sigs.k8s.io/yaml v1.2.0
)
