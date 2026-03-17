/*
 * Package responsible for receiving incoming mount requests from the driver.
 *
 * This package acts as the high level orchestrator; unpacking the message and
 * calling the provider implementation to fetch the secrets.
 *
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

	"github.com/aws/secrets-store-csi-driver-provider-aws/credential_provider"
	"github.com/aws/secrets-store-csi-driver-provider-aws/provider"
	"github.com/aws/secrets-store-csi-driver-provider-aws/utils"
)

// Version filled in by Makefile during build.
var Version string

const (
	ProviderName = "secrets-store-csi-driver-provider-aws"

	namespaceAttrib            = "csi.storage.k8s.io/pod.namespace"
	acctAttrib                 = "csi.storage.k8s.io/serviceAccount.name"
	podnameAttrib              = "csi.storage.k8s.io/pod.name"
	serviceAccountTokensAttrib = "csi.storage.k8s.io/serviceAccount.tokens"
	regionAttrib               = "region"                        // The attribute name for the region in the SecretProviderClass
	transAttrib                = "pathTranslation"               // Path translation char
	regionLabel                = "topology.kubernetes.io/region" // The node label giving the region
	secProvAttrib              = "objects"                       // The attribute used to pass the SecretProviderClass definition (with what to mount)
	failoverRegionAttrib       = "failoverRegion"                // The attribute name for the failover region in the SecretProviderClass
	usePodIdentityAttrib       = "usePodIdentity"                // The attribute used to indicate use Pod Identity for auth
	preferredAddressTypeAttrib = "preferredAddressType"          // The attribute used to indicate IP address preference (IPv4 or IPv6) for network connections. It controls whether connecting to the Pod Identity Agent IPv4 or IPv6 endpoint.
	roleArnAnnotation          = "eks.amazonaws.com/role-arn"
)

// ProviderVersion is injected at build time from the Makefile.
var ProviderVersion = "unknown"

// CSIDriverProviderServer implements the Secrets Store CSI Driver provider for AWS.
//
// This server receives mount requests and then retrieves and stores the secrets
// from that request. The details of what secrets are required and where to
// store them are in the request. The secrets will be retrieved using the AWS
// credentials of the IAM role associated with the pod. If there is a failure
// during the mount of any one secret no secrets are written to the mount point.
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

// appID returns the User-Agent app identifier string.
func (s *CSIDriverProviderServer) appID() string {
	version := ProviderVersion
	if s.eksAddonVersion != "" {
		version = s.eksAddonVersion
	}
	return ProviderName + "-" + version
}

// Mount handles each incoming mount request.
//
// The provider will fetch the secret value from the secret provider (Parameter
// Store or Secrets Manager) and write the secrets to the mount point. The
// version ids of the secrets are then returned to the driver.
func (s *CSIDriverProviderServer) Mount(ctx context.Context, req *v1alpha1.MountRequest) (response *v1alpha1.MountResponse, e error) {
	// Log out the write mode
	if s.driverWriteSecrets {
		klog.Infof("Driver is configured to write secrets")
	} else {
		klog.Infof("Provider is configured to write secrets")
	}

	// Basic sanity check
	if len(req.GetTargetPath()) == 0 {
		return nil, fmt.Errorf("Missing mount path")
	}
	mountDir := req.GetTargetPath()

	// Unpack the request.
	var attrib map[string]string
	err := json.Unmarshal([]byte(req.GetAttributes()), &attrib)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal attributes, error: %+v", err)
	}

	// Get the mount attributes.
	nameSpace := attrib[namespaceAttrib]
	svcAcct := attrib[acctAttrib]
	podName := attrib[podnameAttrib]
	region := attrib[regionAttrib]
	translate := attrib[transAttrib]
	failoverRegion := attrib[failoverRegionAttrib]
	usePodIdentityStr := attrib[usePodIdentityAttrib]
	preferredAddressType := attrib[preferredAddressTypeAttrib]
	serviceAccountTokens := attrib[serviceAccountTokensAttrib]

	// Parse CSI tokens once upfront for clear error reporting.
	parsedTokens, err := utils.ParseServiceAccountTokens(serviceAccountTokens)
	if err != nil {
		return nil, fmt.Errorf("CSI token error: %w - ensure tokenRequests is configured in CSIDriver spec", err)
	}

	// Make a map of the currently mounted versions (if any)
	curVersions := req.GetCurrentObjectVersion()
	curVerMap := make(map[string]*v1alpha1.ObjectVersion)
	for _, ver := range curVersions {
		curVerMap[ver.Id] = ver
	}

	// Unpack the file permission to use.
	var filePermission os.FileMode
	err = json.Unmarshal([]byte(req.GetPermission()), &filePermission)
	if err != nil {
		return nil, fmt.Errorf("failed to unmarshal file permission, error: %+v", err)
	}

	// Set the default file permission
	provider.SetDefaultFilePermission(filePermission)

	regions, err := s.getAwsRegions(ctx, region, failoverRegion, nameSpace, podName)
	if err != nil {
		klog.ErrorS(err, "Failed to initialize AWS session")
		return nil, err
	}

	klog.Infof("Servicing mount request for pod %s in namespace %s using service account %s with region(s) %s", podName, nameSpace, svcAcct, strings.Join(regions, ", "))

	// Default to use IRSA if usePodIdentity parameter is not set in the mount request
	usePodIdentity := false
	if usePodIdentityStr != "" {
		usePodIdentity, err = strconv.ParseBool(usePodIdentityStr)
		if err != nil {
			return nil, fmt.Errorf("failed to parse usePodIdentity value, error: %+v", err)
		}
	}

	// Extract the specific token needed for the chosen auth method.
	var token string
	var roleArn string
	if usePodIdentity {
		token, err = utils.GetTokenForAudience(parsedTokens, utils.PodIdentityAudience)
		if err != nil {
			return nil, fmt.Errorf("Pod Identity token extraction failed: %w", err)
		}
	} else {
		token, err = utils.GetTokenForAudience(parsedTokens, utils.IRSAAudience)
		if err != nil {
			return nil, fmt.Errorf("IRSA token extraction failed: %w", err)
		}
		roleArn, err = s.getRoleARN(ctx, nameSpace, svcAcct)
		if err != nil {
			return nil, err
		}
	}

	awsConfigs, err := s.getAwsConfigs(ctx, regions, usePodIdentity, preferredAddressType, roleArn, token)
	if err != nil {
		return nil, err
	}
	if len(awsConfigs) > 2 {
		return nil, fmt.Errorf("Max number of region(s) exceeded: %s", strings.Join(regions, ", "))
	}

	// Get the list of secrets to mount. These will be grouped together by type
	// in a map of slices (map[string][]*SecretDescriptor) keyed by secret type
	// so that requests can be batched if the implementation allows it.
	descriptors, err := provider.NewSecretDescriptorList(mountDir, translate, attrib[secProvAttrib], regions)
	if err != nil {
		klog.Errorf("Failure reading descriptor list: %s", err)
		return nil, err
	}

	providerFactory := s.secretProviderFactory(awsConfigs, regions)
	var fetchedSecrets []*provider.SecretValue
	for sType := range descriptors { // Iterate over each secret type.
		// Fetch all the secrets and update the curVerMap
		provider := providerFactory.GetSecretProvider(sType)
		secrets, err := provider.GetSecretValues(ctx, descriptors[sType], curVerMap)
		if err != nil {
			klog.Errorf("Failure getting secret values from provider type %s: %s", sType, err)
			return nil, err
		}
		fetchedSecrets = append(fetchedSecrets, secrets...) // Build up the list of all secrets
	}

	// Write out the secrets to the mount point after everything is fetched.
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

	// Build the version response from the current version map and return it.
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
		return "", fmt.Errorf("An IAM role must be associated with service account %s (namespace: %s)", svcAcct, nameSpace)
	}
	klog.Infof("Role ARN for %s:%s is %s", nameSpace, svcAcct, roleArn)
	return roleArn, nil
}

// getAwsRegions resolves the primary and optional failover region for a mount request.
//
// When a region in the mount request is available, the region is added as primary region to the lookup region list
// If a region is not specified in the mount request, we must lookup the region from node label and add as primary region to the lookup region list
// If both the region and node label region are not available, error will be thrown
// If backupRegion is provided and is equal to region/node region, error will be thrown else backupRegion is added to the lookup region list
func (s *CSIDriverProviderServer) getAwsRegions(ctx context.Context, region, backupRegion, nameSpace, podName string) (response []string, err error) {
	var lookupRegionList []string

	// Find primary region.  Fall back to region node if unavailable.
	if len(region) == 0 {
		region, err = s.getRegionFromNode(ctx, nameSpace, podName)
		if err != nil {
			return nil, fmt.Errorf("failed to retrieve region from node. error %+v", err)
		}
	}
	lookupRegionList = []string{region}

	// Find backup region
	if len(backupRegion) > 0 {
		if region == backupRegion {
			return nil, fmt.Errorf("%v: failover region cannot be the same as the primary region", region)
		}
		lookupRegionList = append(lookupRegionList, backupRegion)
	}
	return lookupRegionList, nil
}

// getAwsConfigs builds an AWS config for each lookup region using the pod's credentials.
func (s *CSIDriverProviderServer) getAwsConfigs(ctx context.Context, regions []string, usePodIdentity bool, preferredAddressType, roleArn, token string) ([]aws.Config, error) {
	var configs []aws.Config
	appID := s.appID()

	for _, region := range regions {
		var credProvider credential_provider.ConfigProvider
		var err error

		if usePodIdentity {
			credProvider, err = credential_provider.NewPodIdentityCredentialProvider(region, preferredAddressType, s.podIdentityHttpTimeout, appID, token)
		} else {
			credProvider, err = credential_provider.NewIRSACredentialProvider(region, roleArn, appID, token)
		}
		if err != nil {
			return nil, fmt.Errorf("%s: %s", region, err)
		}

		cfg, err := credProvider.GetAWSConfig(ctx)
		if err != nil {
			return nil, fmt.Errorf("%s: %s", region, err)
		}
		configs = append(configs, cfg)
	}

	return configs, nil
}

// Version returns the provider plugin version information.
func (s *CSIDriverProviderServer) Version(ctx context.Context, req *v1alpha1.VersionRequest) (*v1alpha1.VersionResponse, error) {

	return &v1alpha1.VersionResponse{
		Version:        "v1alpha1",
		RuntimeName:    ProviderName,
		RuntimeVersion: Version,
	}, nil

}

// getRegionFromNode resolves the AWS region by looking up the pod's node and
// reading the topology.kubernetes.io/region label. Falls back to AWS_REGION env var.
//
// When a region is not specified in the mount request, we must lookup the
// region of the requesting pod by first describing the pod to find the node and
// then describing the node to get the region label.
//
// See also: https://pkg.go.dev/k8s.io/client-go/kubernetes/typed/core/v1
func (s *CSIDriverProviderServer) getRegionFromNode(ctx context.Context, namespace string, podName string) (reg string, err error) {

	// Check if AWS_REGION environment variable is set
	if envRegion := os.Getenv("AWS_REGION"); envRegion != "" {
		return envRegion, nil
	}

	// Describe the pod to find the node: kubectl -o yaml -n <namespace> get pod <podid>
	pod, err := s.k8sClient.Pods(namespace).Get(ctx, podName, metav1.GetOptions{})
	if err != nil {
		return "", err
	}

	// Describe node to get region: kubectl -o yaml -n <namespace> get node <nodeid>
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

// writeFile writes a secret to the mount point. Uses a temp file + rename for
// near-atomic updates to avoid pods reading partial files during rotation.
//
// If the driver writes the secrets just return the driver data. Otherwise,
// we write the secret to a temp file and then rename in order to get as close
// to an atomic update as the file system supports. This is to avoid having
// pod applications inadvertently reading an empty or partial files as it is
// being updated.
func (s *CSIDriverProviderServer) writeFile(secret *provider.SecretValue, mode os.FileMode) (*v1alpha1.File, error) {

	// Don't write if the driver is supposed to do it.
	if s.driverWriteSecrets {

		return &v1alpha1.File{
			Path:     secret.Descriptor.GetFileName(),
			Mode:     int32(mode),
			Contents: secret.Value,
		}, nil

	}

	// Write to a tempfile first
	tmpFile, err := os.CreateTemp(secret.Descriptor.GetMountDir(), secret.Descriptor.GetFileName())
	if err != nil {
		return nil, err
	}
	defer os.Remove(tmpFile.Name()) // Cleanup on fail
	defer tmpFile.Close()           // Don't leak file descriptors

	err = tmpFile.Chmod(mode) // Set correct permissions
	if err != nil {
		return nil, err
	}

	_, err = tmpFile.Write(secret.Value) // Write the secret
	if err != nil {
		return nil, err
	}

	err = tmpFile.Sync() // Make sure to flush to disk
	if err != nil {
		return nil, err
	}

	// Swap out the old secret for the new
	err = os.Rename(tmpFile.Name(), secret.Descriptor.GetMountPath())
	if err != nil {
		return nil, err
	}

	return nil, nil
}
