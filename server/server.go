/*
 * Package responsible for reciving incomming mount requests from the driver.
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
	"io/ioutil"
	"os"
	"strconv"
	"strings"

	"k8s.io/klog/v2"

	"google.golang.org/grpc"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"

	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/secrets-store-csi-driver-provider-aws/auth"
	"github.com/aws/secrets-store-csi-driver-provider-aws/provider"
)

// Version filled in by Makefile during build.
var Version string

const (
	namespaceAttrib            = "csi.storage.k8s.io/pod.namespace"
	acctAttrib                 = "csi.storage.k8s.io/serviceAccount.name"
	podnameAttrib              = "csi.storage.k8s.io/pod.name"
	regionAttrib               = "region"                        // The attribute name for the region in the SecretProviderClass
	transAttrib                = "pathTranslation"               // Path translation char
	regionLabel                = "topology.kubernetes.io/region" // The node label giving the region
	secProvAttrib              = "objects"                       // The attribute used to pass the SecretProviderClass definition (with what to mount)
	failoverRegionAttrib       = "failoverRegion"                // The attribute name for the failover region in the SecretProviderClass
	usePodIdentityAttrib       = "usePodIdentity"                // The attribute used to indicate use Pod Identity for auth
	preferredAddressTypeAttrib = "preferredAddressType"          // The attribute used to indicate IP address preference (IPv4 or IPv6) for network connections. It controls whether connecting to the Pod Identity Agent IPv4 or IPv6 endpoint.
)

// A Secrets Store CSI Driver provider implementation for AWS Secrets Manager and SSM Parameter Store.
//
// This server receives mount requests and then retreives and stores the secrets
// from that request. The details of what secrets are required and where to
// store them are in the request. The secrets will be retrieved using the AWS
// credentials of the IAM role associated with the pod. If there is a failure
// during the mount of any one secret no secrets are written to the mount point.
type CSIDriverProviderServer struct {
	*grpc.Server
	secretProviderFactory provider.ProviderFactoryFactory
	k8sClient             k8sv1.CoreV1Interface
	driverWriteSecrets    bool
}

// Factory function to create the server to handle incoming mount requests.
func NewServer(
	secretProviderFact provider.ProviderFactoryFactory,
	k8client k8sv1.CoreV1Interface,
	driverWriteSecrets bool,
) (srv *CSIDriverProviderServer, e error) {

	return &CSIDriverProviderServer{
		secretProviderFactory: secretProviderFact,
		k8sClient:             k8client,
		driverWriteSecrets:    driverWriteSecrets,
	}, nil

}

// Mount handles each incomming mount request.
//
// The provider will fetch the secret value from the secret provider (Parameter
// Store or Secrets Manager) and write the secrets to the mount point. The
// version ids of the secrets are then returned to the driver.
func (s *CSIDriverProviderServer) Mount(ctx context.Context, req *v1alpha1.MountRequest) (response *v1alpha1.MountResponse, e error) {

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

	regions, err := s.getAwsRegions(region, failoverRegion, nameSpace, podName, ctx)
	if err != nil {
		klog.ErrorS(err, "Failed to initialize AWS session")
		return nil, err
	}

	klog.Infof("Servicing mount request for pod %s in namespace %s using service account %s with region(s) %s", podName, nameSpace, svcAcct, strings.Join(regions, ", "))

	// Default to use IRSA if usePodIdentity parameter is not set in the mount request
	usePodIdentity := false
	if usePodIdentityStr != "" {
		var err error
		usePodIdentity, err = strconv.ParseBool(usePodIdentityStr)
		if err != nil {
			return nil, fmt.Errorf("failed to parse usePodIdentity value, error: %+v", err)
		}
	}

	awsSessions, err := s.getAwsSessions(nameSpace, svcAcct, ctx, regions, usePodIdentity, podName, preferredAddressType)
	if err != nil {
		return nil, err
	}
	if len(awsSessions) > 2 {
		klog.Errorf("Max number of region(s) exceeded: %s", strings.Join(regions, ", "))
		return nil, err
	}

	// Get the list of secrets to mount. These will be grouped together by type
	// in a map of slices (map[string][]*SecretDescriptor) keyed by secret type
	// so that requests can be batched if the implementation allows it.
	descriptors, err := provider.NewSecretDescriptorList(mountDir, translate, attrib[secProvAttrib], regions)
	if err != nil {
		klog.Errorf("Failure reading descriptor list: %s", err)
		return nil, err
	}

	providerFactory := s.secretProviderFactory(awsSessions, regions)
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

		file, err := s.writeFile(secret, filePermission)
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

// Private helper to get the aws lookup regions for a given pod.
//
// When a region in the mount request is available, the region is added as primary region to the lookup region list
// If a region is not specified in the mount request, we must lookup the region from node label and add as primary region to the lookup region list
// If both the region and node label region are not available, error will be thrown
// If backupRegion is provided and is equal to region/node region, error will be thrown else backupRegion is added to the lookup region list
func (s *CSIDriverProviderServer) getAwsRegions(region, backupRegion, nameSpace, podName string, ctx context.Context) (response []string, err error) {
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

// Private helper to get the aws sessions for all the lookup regions for a given pod.
//
// Gets the pod's AWS creds for each lookup region
// Establishes the connection using Aws cred for each lookup region
// If atleast one session is not created, error will be thrown
func (s *CSIDriverProviderServer) getAwsSessions(nameSpace, svcAcct string, ctx context.Context, lookupRegionList []string, usePodIdentity bool, podName string, preferredAddressType string) (response []*session.Session, err error) {
	// Get the pod's AWS creds for each lookup region.
	var awsSessionsList []*session.Session

	for _, region := range lookupRegionList {
		awsAuth, err := auth.NewAuth(ctx, region, nameSpace, svcAcct, podName, preferredAddressType, usePodIdentity, s.k8sClient)
		if err != nil {
			return nil, fmt.Errorf("%s: %s", region, err)
		}
		awsSession, err := awsAuth.GetAWSSession()
		if err != nil {
			return nil, fmt.Errorf("%s: %s", region, err)
		}
		awsSessionsList = append(awsSessionsList, awsSession)
	}

	return awsSessionsList, nil
}

// Return the provider plugin version information to the driver.
func (s *CSIDriverProviderServer) Version(ctx context.Context, req *v1alpha1.VersionRequest) (*v1alpha1.VersionResponse, error) {

	return &v1alpha1.VersionResponse{
		Version:        "v1alpha1",
		RuntimeName:    auth.ProviderName,
		RuntimeVersion: Version,
	}, nil

}

// Private helper to get the region information for a given pod.
//
// When a region is not specified in the mount request, we must lookup the
// region of the requesting pod by first descriing the pod to find the node and
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

// Private helper to write a new secret or perform an update on a previously mounted secret.
//
// If the driver writes the secrets just return the dirver data. Otherwise,
// we write the secret to a temp file and then rename in order to get as close
// to an atomic update as the file system supports. This is to avoid having
// pod applications inadvertantly reading an empty or partial files as it is
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
	tmpFile, err := ioutil.TempFile(secret.Descriptor.GetMountDir(), secret.Descriptor.GetFileName())
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
