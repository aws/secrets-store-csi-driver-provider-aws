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
	"path/filepath"
	"strings"

	"google.golang.org/grpc"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/klog/v2"
	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"

	"github.com/aws/secrets-store-csi-driver-provider-aws/auth"
	"github.com/aws/secrets-store-csi-driver-provider-aws/provider"
)

const (
	version         = "1.0.0"
	namespaceAttrib = "csi.storage.k8s.io/pod.namespace"
	acctAttrib      = "csi.storage.k8s.io/serviceAccount.name"
	podnameAttrib   = "csi.storage.k8s.io/pod.name"
	regionAttrib    = "region"                        // The attribute name for the region in the SecretProviderClass
	transAttrib     = "pathTranslation"               // Path translation char
	regionLabel     = "topology.kubernetes.io/region" // The node label giving the region
	secProvAttrib   = "objects"                       // The attributed used to pass the SecretProviderClass definition (with what to mount)
)

// A Secrets Store CSI Driver provider implementation for AWS Secrets Manager and SSM Parameter Store.
//
// This server receives mount requests and then retreives and stores the secrets
// from that request. The details of what secrets are required and where to
// store them are in the request. The secrets will be retrieved using the AWS
// credentials of the IAM role associated with the pod. If there is a failure
// durring the mount of any one secret no secrets are written to the mount point.
//
type CSIDriverProviderServer struct {
	*grpc.Server
	secretProviderFactory provider.ProviderFactoryFactory
	k8sClient             k8sv1.CoreV1Interface
}

// Factory function to create the server to handle incoming mount requests.
//
func NewServer(
	secretProviderFact provider.ProviderFactoryFactory,
	k8client k8sv1.CoreV1Interface,
) (srv *CSIDriverProviderServer, e error) {

	return &CSIDriverProviderServer{
		secretProviderFactory: secretProviderFact,
		k8sClient:             k8client,
	}, nil

}

// Mount handles each incomming mount request.
//
// The provider will fetch the secret value from the secret provider (Parameter
// Store or Secrets Manager) and write the secrets to the mount point. The
// version ids of the secrets are then returned to the driver.
//
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

	// See if we should substitite underscore for slash
	translate := attrib[transAttrib]
	if len(translate) == 0 {
		translate = "_" // Use default
	} else if strings.ToLower(translate) == "false" {
		translate = "" // Turn it off.
	} else if len(translate) != 1 {
		return nil, fmt.Errorf("%s must be either 'False' or a single character string", transAttrib)
	}

	// Lookup the region if one was not specified.
	if len(region) <= 0 {
		region, err = s.getRegionFromNode(ctx, nameSpace, podName)
		if err != nil {
			return nil, fmt.Errorf("failed to retrieve region from node. error %+v", err)
		}
	}

	klog.Infof("Servicing mount request for pod %s in namespace %s using service account %s with region %s", podName, nameSpace, svcAcct, region)

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

	// Get the pod's AWS creds.
	oidcAuth, err := auth.NewAuth(ctx, region, nameSpace, svcAcct, s.k8sClient)
	if err != nil {
		return nil, err
	}
	awsSession, err := oidcAuth.GetAWSSession()
	if err != nil {
		klog.ErrorS(err, "Failed to initialize AWS session")
		return nil, err
	}

	// Get the list of secrets to mount. These will be grouped together by type
	// in a map of slices (map[string][]*SecretDescriptor) keyed by secret type
	// so that requests can be batched if the implementation allows it.
	descriptors, err := provider.NewSecretDescriptorList(attrib[secProvAttrib])
	if err != nil {
		return nil, err
	}

	// Fetch all secrets before saving so we write nothing on failure.
	providerFactory := s.secretProviderFactory(region, awsSession)
	var fetchedSecrets []*provider.SecretValue
	for sType := range descriptors { // Iterate over each secret type.

		// Fetch all the the secrets and update the curVerMap
		provider := providerFactory.GetSecretProvider(sType)
		secrets, err := provider.GetSecretValues(ctx, descriptors[sType], curVerMap)
		if err != nil {
			return nil, err
		}

		fetchedSecrets = append(fetchedSecrets, secrets...) // Build up the list of all secrets
	}

	// Write out the secrets to the mount point after everything is fetched.
	for _, secret := range fetchedSecrets {
		err := writeFile(mountDir, secret.Descriptor.GetFileName(), secret.Value, filePermission, translate)
		if err != nil {
			return nil, err
		}
	}

	// Build the version response from the current version map and return it.
	var ov []*v1alpha1.ObjectVersion
	for id := range curVerMap {
		ov = append(ov, curVerMap[id])
	}
	return &v1alpha1.MountResponse{ObjectVersion: ov}, nil

}

// Return the provider plugin version information to the driver.
//
func (s *CSIDriverProviderServer) Version(ctx context.Context, req *v1alpha1.VersionRequest) (*v1alpha1.VersionResponse, error) {

	return &v1alpha1.VersionResponse{
		Version:        "v1alpha1",
		RuntimeName:    auth.ProviderName,
		RuntimeVersion: version,
	}, nil

}

// Private helper to get the region information for a given pod.
//
// When a region is not specified in the mount request, we must lookup the
// region of the requesting pod by first descriing the pod to find the node and
// then describing the node to get the region label.
//
// See also: https://pkg.go.dev/k8s.io/client-go/kubernetes/typed/core/v1
//
func (s *CSIDriverProviderServer) getRegionFromNode(ctx context.Context, namespace string, podName string) (reg string, err error) {

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
// We write the secret to a temp file and then rename in order to get as close
// to an atomic update as the file system supports. This is to avoid having
// pod applications inadvertantly reading an empty or partial files as it is
// being updated.
//
func writeFile(dir, fileName string, value []byte, mode os.FileMode, translate string) error {

	// Translate slashes to underscore if required.
	if len(translate) != 0 {
		fileName = strings.ReplaceAll(fileName, string(os.PathSeparator), translate)
	}

	// Write to a tempfile first
	tmpFile, err := ioutil.TempFile(dir, fileName)
	if err != nil {
		return err
	}
	defer os.Remove(tmpFile.Name()) // Cleanup on fail
	defer tmpFile.Close()           // Don't leak file descriptors

	err = tmpFile.Chmod(mode) // Set correct permissions
	if err != nil {
		return err
	}

	_, err = tmpFile.Write(value) // Write the secret
	if err != nil {
		return err
	}

	err = tmpFile.Sync() // Make sure to flush to disk
	if err != nil {
		return err
	}

	// Swap out the old secret for the new
	err = os.Rename(tmpFile.Name(), filepath.Join(dir, fileName))
	if err != nil {
		return err
	}

	return nil
}
