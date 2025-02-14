package credential_provider

import (
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
)

// CredentialProvider interface defines methods for obtaining AWS credentials configuration
type CredentialProvider interface {
	// GetAWSConfig returns an AWS configuration containing credentials obtained from the provider
	GetAWSConfig() (*aws.Config, error)
}

// authTokenFetcher interface defines methods for fetching a token given a K8s namespace and service account.
// It matches stscreds.TokenFetcher interface.
type authTokenFetcher interface {
	FetchToken(ctx credentials.Context) ([]byte, error)
}
