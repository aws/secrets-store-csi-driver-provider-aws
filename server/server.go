/*
 * Package responsible for receiving incoming mount requests from the driver.
 */
package server

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strconv"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"

	"google.golang.org/grpc"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/klog/v2"
	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"

	"github.com/aws/secrets-store-csi-driver-provider-aws/auth"
	"github.com/aws/secrets-store-csi-driver-provider-aws/provider"
)

// Version filled in by Makefile during build.
var Version string

const (
	namespaceAttrib            = "csi.storage.k8s.io/pod.namespace"
	acctAttrib                 = "csi.storage.k8s.io/serviceAccount.name"
	podnameAttrib              = "csi.storage.k8s.io/pod.name"
	serviceAccountTokensAttrib = "csi.storage.k8s.io/serviceAccount.tokens"
	regionAttrib               = "region"
	transAttrib                = "pathTranslation"
	regionLabel                = "topology.kubernetes.io/region"
	secProvAttrib              = "objects"
	failoverRegionAttrib       = "failoverRegion"
	usePodIdentityAttrib       = "usePodIdentity"
	preferredAddressTypeAttrib = "preferredAddressType"
	roleArnAnnotation          = "eks.amazonaws.com/role-arn"
)

// CSIDriverProviderServer implements the Secrets Store CSI Driver provider for AWS.
type CSIDriverProviderServer struct {
	*grpc.Server
	secretProviderFactory  provider.ProviderFactoryFactory
	k8sClient              k8sv1.CoreV1Interface
	driverWriteSecrets     bool
	podIdentityHttpTimeout *time.Duration
	eksAddonVersion        string
}

// NewServer creates the server to handle incoming mount requests.
func NewServer(
	secretProviderFact provider.ProviderFactoryFactory,
	k8client k8sv1.CoreV1Interface,
	driverWriteSecrets bool,
	podIdentityHttpTimeout *time.Duration,
	eksAddonVersion string,
) (srv *CSIDriverProviderServer, e error) {
	return &CSIDriverProviderServer{
		secretProviderFactory:  secretProviderFact,
		k8sClient:              k8client,
		driverWriteSecrets:     driverWriteSecrets,
		podIdentityHttpTimeout: podIdentityHttpTimeout,
		eksAddonVersion:        eksAddonVersion,
	}, nil
}

// Mount handles each incoming mount request.
func (s *CSIDriverProviderServer) Mount(ctx context.Context, req *v1alpha1.MountRequest) (response *v1alpha1.MountResponse, e error) {
	if s.driverWriteSecrets {
		klog.Infof("Driver is configured to write secrets")
	} else {
		klog.Infof("Provider is configured to write secrets")
	}

	if len(req.GetTargetPath()) == 0 {
		return nil, fmt.Errorf("Missing mount path")
	}
	mountDir := req.GetTargetPath()

	var attrib map[string]string
	err := json.Unmarshal([]byte(req.GetAttributes()), &attrib)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal attributes, error: %+v", err)
	}

	nameSpace := attrib[namespaceAttrib]
	svcAcct := attrib[acctAttrib]
	podName := attrib[podnameAttrib]
	region := attrib[regionAttrib]
	translate := attrib[transAttrib]
	failoverRegion := attrib[failoverRegionAttrib]
	usePodIdentityStr := attrib[usePodIdentityAttrib]
	preferredAddressType := attrib[preferredAddressTypeAttrib]
	serviceAccountTokens := attrib[serviceAccountTokensAttrib]

	if serviceAccountTokens == "" {
		return nil, fmt.Errorf("no CSI tokens provided - ensure tokenRequests is configured in CSIDriver spec")
	}

	if preferredAddressType != "ipv4" && preferredAddressType != "ipv6" && preferredAddressType != "auto" && preferredAddressType != "" {
		return nil, fmt.Errorf("invalid preferred address type: %s", preferredAddressType)
	}

	curVersions := req.GetCurrentObjectVersion()
	curVerMap := make(map[string]*v1alpha1.ObjectVersion)
	for _, ver := range curVersions {
		curVerMap[ver.Id] = ver
	}

	var filePermission os.FileMode
	err = json.Unmarshal([]byte(req.GetPermission()), &filePermission)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal file permission, error: %+v", err)
	}
	provider.SetDefaultFilePermission(filePermission)

	regions, err := s.getAwsRegions(ctx, region, failoverRegion, nameSpace, podName)
	if err != nil {
		klog.ErrorS(err, "Failed to initialize AWS session")
		return nil, err
	}

	klog.Infof("Servicing mount request for pod %s in namespace %s using service account %s with region(s) %s", podName, nameSpace, svcAcct, strings.Join(regions, ", "))

	usePodIdentity := false
	if usePodIdentityStr != "" {
		usePodIdentity, err = strconv.ParseBool(usePodIdentityStr)
		if err != nil {
			return nil, fmt.Errorf("failed to parse usePodIdentity value, error: %+v", err)
		}
	}

	// Get role ARN for IRSA (not needed for Pod Identity)
	var roleArn string
	if !usePodIdentity {
		roleArn, err = s.getRoleARN(ctx, nameSpace, svcAcct)
		if err != nil {
			return nil, err
		}
	}

	awsConfigs, err := s.getAwsConfigs(ctx, nameSpace, svcAcct, s.eksAddonVersion, regions, usePodIdentity, preferredAddressType, s.podIdentityHttpTimeout, roleArn, serviceAccountTokens)
	if err != nil {
		return nil, err
	}
	if len(awsConfigs) > 2 {
		klog.Errorf("Max number of region(s) exceeded: %s", strings.Join(regions, ", "))
		return nil, err
	}

	descriptors, err := provider.NewSecretDescriptorList(mountDir, translate, attrib[secProvAttrib], regions)
	if err != nil {
		klog.Errorf("Failure reading descriptor list: %s", err)
		return nil, err
	}

	providerFactory := s.secretProviderFactory(awsConfigs, regions)
	var fetchedSecrets []*provider.SecretValue
	for sType := range descriptors {
		prov := providerFactory.GetSecretProvider(sType)
		secrets, err := prov.GetSecretValues(ctx, descriptors[sType], curVerMap)
		if err != nil {
			klog.Errorf("Failure getting secret values from provider type %s: %s", sType, err)
			return nil, err
		}
		fetchedSecrets = append(fetchedSecrets, secrets...)
	}

	var files []*v1alpha1.File
	for _, secret := range fetchedSecrets {
		file, err := s.writeFile(secret, secret.Descriptor.GetFilePermission())
		if err != nil {
			return nil, err
		}
		if file != nil {
			files = append(files, file)
		}
	}

	var ov []*v1alpha1.ObjectVersion
	for id := range curVerMap {
		ov = append(ov, curVerMap[id])
	}
	return &v1alpha1.MountResponse{Files: files, ObjectVersion: ov}, nil
}

// getRoleARN looks up the IAM role ARN from the service account annotation.
func (s *CSIDriverProviderServer) getRoleARN(ctx context.Context, nameSpace, svcAcct string) (string, error) {
	rsp, err := s.k8sClient.ServiceAccounts(nameSpace).Get(ctx, svcAcct, metav1.GetOptions{})
	if err != nil {
		return "", fmt.Errorf("failed to get service account %s/%s: %w", nameSpace, svcAcct, err)
	}
	roleArn := rsp.Annotations[roleArnAnnotation]
	if roleArn == "" {
		return "", fmt.Errorf("IAM role must be associated with service account %s (namespace: %s) - https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html", svcAcct, nameSpace)
	}
	klog.Infof("Role ARN for %s:%s is %s", nameSpace, svcAcct, roleArn)
	return roleArn, nil
}

func (s *CSIDriverProviderServer) getAwsRegions(ctx context.Context, region, backupRegion, nameSpace, podName string) (response []string, err error) {
	var lookupRegionList []string

	if len(region) == 0 {
		region, err = s.getRegionFromNode(ctx, nameSpace, podName)
		if err != nil {
			return nil, fmt.Errorf("failed to retrieve region from node. error %+v", err)
		}
	}
	lookupRegionList = []string{region}

	if len(backupRegion) > 0 {
		if region == backupRegion {
			return nil, fmt.Errorf("%v: failover region cannot be the same as the primary region", region)
		}
		lookupRegionList = append(lookupRegionList, backupRegion)
	}
	return lookupRegionList, nil
}

func (s *CSIDriverProviderServer) getAwsConfigs(ctx context.Context, nameSpace, svcAcct, eksAddonVersion string, lookupRegionList []string, usePodIdentity bool, preferredAddressType string, podIdentityHttpTimeout *time.Duration, roleArn, serviceAccountTokens string) (response []aws.Config, err error) {
	var awsConfigsList []aws.Config

	for _, region := range lookupRegionList {
		awsAuth, err := auth.NewAuth(region, nameSpace, svcAcct, preferredAddressType, eksAddonVersion, roleArn, usePodIdentity, podIdentityHttpTimeout, serviceAccountTokens)
		if err != nil {
			return nil, fmt.Errorf("%s: %s", region, err)
		}
		awsConfig, err := awsAuth.GetAWSConfig(ctx)
		if err != nil {
			return nil, fmt.Errorf("%s: %s", region, err)
		}
		awsConfigsList = append(awsConfigsList, awsConfig)
	}

	return awsConfigsList, nil
}

// Version returns the provider plugin version information.
func (s *CSIDriverProviderServer) Version(ctx context.Context, req *v1alpha1.VersionRequest) (*v1alpha1.VersionResponse, error) {
	return &v1alpha1.VersionResponse{
		Version:        "v1alpha1",
		RuntimeName:    auth.ProviderName,
		RuntimeVersion: Version,
	}, nil
}

func (s *CSIDriverProviderServer) getRegionFromNode(ctx context.Context, namespace string, podName string) (reg string, err error) {
	if envRegion := os.Getenv("AWS_REGION"); envRegion != "" {
		return envRegion, nil
	}

	pod, err := s.k8sClient.Pods(namespace).Get(ctx, podName, metav1.GetOptions{})
	if err != nil {
		return "", err
	}

	nodeName := pod.Spec.NodeName
	node, err := s.k8sClient.Nodes().Get(ctx, nodeName, metav1.GetOptions{})
	if err != nil {
		return "", err
	}

	labels := node.ObjectMeta.Labels
	region := labels[regionLabel]

	if len(region) == 0 {
		return "", fmt.Errorf("Region not found")
	}

	return region, nil
}

func (s *CSIDriverProviderServer) writeFile(secret *provider.SecretValue, mode os.FileMode) (*v1alpha1.File, error) {
	if s.driverWriteSecrets {
		return &v1alpha1.File{
			Path:     secret.Descriptor.GetFileName(),
			Mode:     int32(mode),
			Contents: secret.Value,
		}, nil
	}

	tmpFile, err := os.CreateTemp(secret.Descriptor.GetMountDir(), secret.Descriptor.GetFileName())
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmpFile.Name())
	defer tmpFile.Close()

	err = tmpFile.Chmod(mode)
	if err != nil {
		return nil, err
	}

	_, err = tmpFile.Write(secret.Value)
	if err != nil {
		return nil, err
	}

	err = tmpFile.Sync()
	if err != nil {
		return nil, err
	}

	err = os.Rename(tmpFile.Name(), secret.Descriptor.GetMountPath())
	if err != nil {
		return nil, err
	}

	return nil, nil
}
