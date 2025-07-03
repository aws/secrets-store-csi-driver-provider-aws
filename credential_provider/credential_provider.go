package credential_provider

import (
	"context"
	"github.com/aws/aws-sdk-go-v2/aws"
)

// ConfigProvider interface defines methods for obtaining AWS credentials configuration
type ConfigProvider interface {
	// GetAWSConfig returns an AWS configuration containing credentials obtained from the provider
	GetAWSConfig(ctx context.Context) (aws.Config, error)
}
