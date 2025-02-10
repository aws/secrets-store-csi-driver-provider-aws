/*
 * Package responsible for fetching secrets from the service.
 *
 * This package defines the abstract interface used to fetch secrets, a factory
 * to supply the concrete implementation for a given secret type, and the
 * various implementations.
 *
 */
package provider

import (
	"context"

	"github.com/aws/aws-sdk-go/aws/session"

	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"
)

// SecretProvider defines the interface for fetching secrets from different AWS services.
// Implementations of this interface handle retrieving secrets from services like
// AWS Secrets Manager and AWS Systems Manager Parameter Store.
type SecretProvider interface {
	GetSecretValues(ctx context.Context, descriptor []*SecretDescriptor, curMap map[string]*v1alpha1.ObjectVersion) (secret []*SecretValue, e error)
}

// SecretProviderMapping maintains a mapping between SecretTypes (secretsmanager or ssmparameter)
// and their corresponding singleton provider instances.
type SecretProviderMaping struct {
	Providers map[SecretType]SecretProvider // Maps secret type to the provider.
}

// SecretProviderMappingGenerator is a type for creating a new SecretProviderMapping with initialized providers
type SecretProviderMappingGenerator func(session []*session.Session, reigons []string) (factory *SecretProviderMaping)

// NewSecretProviderMappingGenerator creates a mapping of secret types to their provider implementations.
// It initializes and returns a SecretProviderMapping containing concrete providers for each supported secret type.
func NewSecretProviderMappingGenerator(sessions []*session.Session, regions []string) (factory *SecretProviderMaping) {
	return &SecretProviderMaping{
		Providers: map[SecretType]SecretProvider{
			SSMParameter:   NewParameterStoreProvider(sessions, regions),
			SecretsManager: NewSecretsManagerProvider(sessions, regions),
		},
	}

}

// GetSecretProvider returns the appropriate SecretProvider implementation for the given secret type.
// It looks up and returns the previously initialized provider from the mapping.
func (p SecretProviderMaping) GetSecretProvider(secretType SecretType) (prov SecretProvider) {
	return p.Providers[secretType]
}
