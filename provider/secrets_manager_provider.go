package provider

import (
	"context"
	"fmt"
	"io/ioutil"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/secretsmanager"
	"github.com/aws/aws-sdk-go/service/secretsmanager/secretsmanageriface"
	"github.com/aws/secrets-store-csi-driver-provider-aws/utils"
	"k8s.io/klog/v2"

	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"
)

// Implements the provider interface for Secrets Manager.
//
// Unlike the ParameterStoreProvider, this implementation is optimized for
// latency and not reduced API call rates becuase Secrets Manager provides
// higher API limits.
//
// When there are no existing versions of the secret (first mount), this
// provider will just call GetSecretValue, update the current version map
// (curMap), and return the secret in the results. When there are existing
// versions (rotation reconciler case), this implementation will use the lower
// latency DescribeSecret call to first determine if the secret has been
// updated.
type SecretsManagerProvider struct {
	clients []SecretsManagerClient
}

// SecretsManager client with region
type SecretsManagerClient struct {
	Region     string
	Client     secretsmanageriface.SecretsManagerAPI
	IsFailover bool
}

// Get the secret from SecretsManager.
//
// This method iterates over all descriptors and requests a fetch. When
// sucessfully fetched, then it continues until all descriptors have been fetched.
// Once an error happens, it immediately returns the error.
func (p *SecretsManagerProvider) GetSecretValues(
	ctx context.Context,
	descriptors []*SecretDescriptor,
	curMap map[string]*v1alpha1.ObjectVersion,
) (v []*SecretValue, errs error) {

	// Fetch each secret in order. If any secret fails we will return that secret's errors
	for _, descriptor := range descriptors {
		values, errs := p.fetchSecretManagerValue(ctx, descriptor, curMap)
		if values == nil {
			return nil, errs
		}
		v = append(v, values...)
	}
	return v, nil
}

// Private helper function to fetch a single secret.
//
// This method iterates over all available clients in the SecretsManagerProvider.
// It requests a fetch from each of them.  Once a fetch succeeds it returns the
//
//	value. If a fetch fails all clients it returns all errors.
func (p *SecretsManagerProvider) fetchSecretManagerValue(
	ctx context.Context,
	descriptor *SecretDescriptor,
	curMap map[string]*v1alpha1.ObjectVersion,
) (value []*SecretValue, err error) {

	for _, client := range p.clients {
		secretVal, err := p.fetchSecretManagerValueWithClient(ctx, client, descriptor, curMap)

		//check if fatal(4XX status error) exist to error out the mount
		if utils.IsFatalError(err) {
			return nil, err
		} else if err != nil {
			klog.Warning(err)
		}

		if len(secretVal) > 0 && len(value) == 0 {
			value = secretVal
		}
	}
	if len(value) == 0 {
		return nil, fmt.Errorf("Failed to fetch secret from all regions. Verify secret exists and required permissions are granted for: %s", descriptor.ObjectName)
	}

	return value, nil
}

// Private helper function to fetch a single secret from a single region
//
// This method checks if the secret is current. If a secret is not current
// (or this is the first time), the secret is fetched, added to the list of
// secrets, and the version information is updated in the current version map.
func (p *SecretsManagerProvider) fetchSecretManagerValueWithClient(
	ctx context.Context,
	client SecretsManagerClient,
	descriptor *SecretDescriptor,
	curMap map[string]*v1alpha1.ObjectVersion,
) (v []*SecretValue, e error) {

	var values []*SecretValue

	// Don't re-fetch if we already have the current version.
	isCurrent, version, err := p.isCurrent(ctx, client, descriptor, curMap)
	if err != nil {
		return nil, err
	}

	// If version is current, read it back in, otherwise pull it down
	var secret *SecretValue
	if isCurrent {
		secret, err = p.reloadSecret(descriptor)
		if err != nil {
			return nil, err
		}
	} else { // Fetch the latest version.
		version, secret, err = p.fetchSecret(ctx, client, descriptor)
		if err != nil {
			return nil, err
		}
	}
	values = append(values, secret) // Build up the slice of values

	//Fetch individual json key value pairs based on jmesPath
	jsonSecrets, jsonError := secret.getJsonSecrets()
	if jsonError != nil {
		return nil, jsonError
	}

	values = append(values, jsonSecrets...)

	// Update the version in the current version map.
	for _, jsonSecret := range jsonSecrets {
		jsonDescriptor := jsonSecret.Descriptor
		curMap[jsonDescriptor.GetFileName()] = &v1alpha1.ObjectVersion{
			Id:      jsonDescriptor.GetFileName(),
			Version: version,
		}
	}

	// Update the version in the current version map.
	curMap[descriptor.GetFileName()] = &v1alpha1.ObjectVersion{
		Id:      descriptor.GetFileName(),
		Version: version,
	}

	return values, nil
}

// Private helper to check if a secret is current.
//
// This method looks for the given secret in the current version map, if it
// does not exist (first time) it is not current. If the requsted secret uses
// the objectVersion parameter, the current version is compared to the required
// version to determine if it is current. Otherwise, the current vesion
// information is fetched using DescribeSecret and this method checks if the
// current version is labeled as current (AWSCURRENT) or has the label
// sepecified via objectVersionLable (if any).
func (p *SecretsManagerProvider) isCurrent(
	ctx context.Context,
	client SecretsManagerClient,
	descriptor *SecretDescriptor,
	curMap map[string]*v1alpha1.ObjectVersion,
) (cur bool, ver string, err error) {

	// If we don't have this version, it is not current.
	curVer := curMap[descriptor.GetFileName()]
	if curVer == nil {
		return false, "", nil
	}

	// If the secret is pinned to a version see if that is what we have.
	if len(descriptor.GetObjectVersion(client.IsFailover)) > 0 {
		return curVer.Version == descriptor.GetObjectVersion(client.IsFailover), curVer.Version, nil
	}

	// Lookup the current version information.
	rsp, err := client.Client.DescribeSecretWithContext(ctx, &secretsmanager.DescribeSecretInput{SecretId: aws.String(descriptor.GetSecretName(client.IsFailover))})
	if err != nil {
		return false, curVer.Version, fmt.Errorf("%s: Failed to describe secret %s: %w", client.Region, descriptor.ObjectName, err)
	}

	// If no label is specified use current, otherwise use the specified label.
	label := "AWSCURRENT"
	if len(descriptor.GetObjectVersionLabel(client.IsFailover)) > 0 {
		label = descriptor.GetObjectVersionLabel(client.IsFailover)
	}

	// Linear search for desired label in the list of labels on current version.
	stages := rsp.VersionIdsToStages[curVer.Version]
	hasLabel := false
	for i := 0; i < len(stages) && !hasLabel; i++ {
		hasLabel = *(stages[i]) == label
	}

	return hasLabel, curVer.Version, nil // If the current version has the desired label, it is current.
}

// Private helper to fetch a given secret.
//
// This method builds up the GetSecretValue request using the objectName from
// the request and any objectVersion or objectVersionLabel parameters.
func (p *SecretsManagerProvider) fetchSecret(
	ctx context.Context,
	client SecretsManagerClient,
	descriptor *SecretDescriptor,
) (ver string, val *SecretValue, err error) {

	req := secretsmanager.GetSecretValueInput{SecretId: aws.String(descriptor.GetSecretName(client.IsFailover))}

	// Use explicit version if specified
	if len(descriptor.GetObjectVersion(client.IsFailover)) != 0 {
		req.SetVersionId(descriptor.GetObjectVersion(client.IsFailover))
	}

	// Use stage label if specified
	if len(descriptor.GetObjectVersionLabel(client.IsFailover)) != 0 {
		req.SetVersionStage(descriptor.GetObjectVersionLabel(client.IsFailover))
	}

	rsp, err := client.Client.GetSecretValueWithContext(ctx, &req)
	if err != nil {
		return "", nil, fmt.Errorf("%s: Failed fetching secret %s: %w", client.Region, descriptor.ObjectName, err)
	}

	// Use either secret string or secret binary.
	var sValue []byte
	if rsp.SecretString != nil {
		sValue = []byte(*rsp.SecretString)
	} else {
		sValue = rsp.SecretBinary
	}

	return *rsp.VersionId, &SecretValue{Value: sValue, Descriptor: *descriptor}, nil
}

// Private helper to refesh a secret from its previously stored value.
//
// Reads a secret back in from the file system.
func (p *SecretsManagerProvider) reloadSecret(descriptor *SecretDescriptor) (val *SecretValue, e error) {

	sValue, err := ioutil.ReadFile(descriptor.GetMountPath())
	if err != nil {
		return nil, err
	}

	return &SecretValue{Value: sValue, Descriptor: *descriptor}, nil
}

// Factory methods to build a new SecretsManagerProvider
func NewSecretsManagerProviderWithClients(clients ...SecretsManagerClient) *SecretsManagerProvider {
	return &SecretsManagerProvider{
		clients: clients,
	}
}

func NewSecretsManagerProvider(awsSessions []*session.Session, regions []string) *SecretsManagerProvider {
	var clients []SecretsManagerClient
	for i, awsSession := range awsSessions {
		client := SecretsManagerClient{
			Region:     *awsSession.Config.Region,
			Client:     secretsmanager.New(awsSession, aws.NewConfig().WithRegion(regions[i])),
			IsFailover: i > 0,
		}
		clients = append(clients, client)
	}
	return NewSecretsManagerProviderWithClients(clients...)
}
