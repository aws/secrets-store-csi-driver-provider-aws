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

// Generic interface for the different secret providers.
type SecretProvider interface {
	GetSecretValues(ctx context.Context, descriptor []*SecretDescriptor, curMap map[string]*v1alpha1.ObjectVersion) (secret []*SecretValue, e error)
}

// Factory class to return singltons based on secret type (secretsmanager or ssmparameter).
type SecretProviderFactory struct {
	Providers map[SecretType]SecretProvider // Maps secret type to the provider.
}

// The prototype for the provider factory fatory
type ProviderFactoryFactory func(session []*session.Session, reigons []string) (factory *SecretProviderFactory)

// Creates the provider factory.
//
// This factory catagorizes the request and returns the correct concrete
// provider implementation using the secret type.
func NewSecretProviderFactory(sessions []*session.Session, regions []string) (factory *SecretProviderFactory) {

	return &SecretProviderFactory{
		Providers: map[SecretType]SecretProvider{
			SSMParameter:   NewParameterStoreProvider(sessions, regions),
			SecretsManager: NewSecretsManagerProvider(sessions, regions),
		},
	}

}

// Factory method to get the correct secret provider for the request type.
//
// This factory method uses the secret type to return the previously created
// provider implementation.
func (p SecretProviderFactory) GetSecretProvider(secretType SecretType) (prov SecretProvider) {
	return p.Providers[secretType]
}
