package provider

import (
	"context"
	"fmt"
	"io/ioutil"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/secretsmanager"
	"github.com/aws/aws-sdk-go/service/secretsmanager/secretsmanageriface"

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
//
type SecretsManagerProvider struct {
	client secretsmanageriface.SecretsManagerAPI
}

// Get the secret from SecretsManager.
//
// This method iterates over each secret in the request and checks if it is
// current. If a secret is not current (or this is the first time), the secret
// is fetched, added to the list of secrets, and the version information is
// updated in the current version map.
//
func (p *SecretsManagerProvider) GetSecretValues(
	ctx context.Context,
	descriptors []*SecretDescriptor,
	curMap map[string]*v1alpha1.ObjectVersion,
) (v []*SecretValue, e error) {

	// Fetch each secret
	var values []*SecretValue
	for _, descriptor := range descriptors {

		// Don't re-fetch if we already have the current version.
		isCurrent, version, err := p.isCurrent(ctx, descriptor, curMap)
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

			version, secret, err = p.fetchSecret(ctx, descriptor)
			if err != nil {
				return nil, err
			}

		}
		values = append(values, secret) // Build up the slice of values

		//Fetch individual json key value pairs based on jmesPath
		jsonSecrets, err := secret.getJsonSecrets()
		if err != nil {
			return nil, err
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
//
func (p *SecretsManagerProvider) isCurrent(
	ctx context.Context,
	descriptor *SecretDescriptor,
	curMap map[string]*v1alpha1.ObjectVersion,
) (cur bool, ver string, e error) {

	// If we don't have this version, it is not current.
	curVer := curMap[descriptor.GetFileName()]
	if curVer == nil {
		return false, "", nil
	}

	// If the secret is pinned to a version see if that is what we have.
	if len(descriptor.ObjectVersion) > 0 {
		return curVer.Version == descriptor.ObjectVersion, curVer.Version, nil
	}

	// Lookup the current version information.
	rsp, err := p.client.DescribeSecretWithContext(ctx, &secretsmanager.DescribeSecretInput{SecretId: aws.String(descriptor.ObjectName)})
	if err != nil {
		return false, curVer.Version, fmt.Errorf("Failed to describe secret %s: %s", descriptor.ObjectName, err.Error())
	}

	// If no label is specified use current, otherwise use the specified label.
	label := "AWSCURRENT"
	if len(descriptor.ObjectVersionLabel) > 0 {
		label = descriptor.ObjectVersionLabel
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
//
func (p *SecretsManagerProvider) fetchSecret(ctx context.Context, descriptor *SecretDescriptor) (ver string, val *SecretValue, e error) {

	req := secretsmanager.GetSecretValueInput{SecretId: aws.String(descriptor.ObjectName)}

	// Use explicit version if specified
	if len(descriptor.ObjectVersion) != 0 {
		req.SetVersionId(descriptor.ObjectVersion)
	}

	// Use stage label if specified
	if len(descriptor.ObjectVersionLabel) != 0 {
		req.SetVersionStage(descriptor.ObjectVersionLabel)
	}

	rsp, err := p.client.GetSecretValueWithContext(ctx, &req)
	if err != nil {
		return "", nil, fmt.Errorf("Failed fetching secret %s: %s", descriptor.ObjectName, err.Error())
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
//
func (p *SecretsManagerProvider) reloadSecret(descriptor *SecretDescriptor) (val *SecretValue, e error) {

	sValue, err := ioutil.ReadFile(descriptor.GetMountPath())
	if err != nil {
		return nil, err
	}

	return &SecretValue{Value: sValue, Descriptor: *descriptor}, nil
}

// Factory methods to build a new SecretsManagerProvider
//
func NewSecretsManagerProviderWithClient(client secretsmanageriface.SecretsManagerAPI) *SecretsManagerProvider {
	return &SecretsManagerProvider{
		client: client,
	}
}
func NewSecretsManagerProvider(region string, awsSession *session.Session) *SecretsManagerProvider {
	secretsManagerClient := secretsmanager.New(awsSession, aws.NewConfig().WithRegion(region))
	return NewSecretsManagerProviderWithClient(secretsManagerClient)
}
