package credential_provider

import (
	"context"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/aws/aws-sdk-go-v2/service/sts"
)

// csiTokenFetcher implements stscreds.IdentityTokenRetriever using a pre-fetched CSI token.
type csiTokenFetcher struct {
	token string
}

func (f *csiTokenFetcher) GetIdentityToken() ([]byte, error) {
	return []byte(f.token), nil
}

// IRSACredentialProvider implements ConfigProvider using IAM Roles for Service Accounts.
type IRSACredentialProvider struct {
	region  string
	roleArn string
	appID   string
	fetcher stscreds.IdentityTokenRetriever
}

// NewIRSACredentialProvider creates a credential provider for IRSA authentication.
// Callers must ensure region, roleArn, and token are non-empty.
func NewIRSACredentialProvider(region, roleArn, appID, token string) (ConfigProvider, error) {
	return &IRSACredentialProvider{
		region:  region,
		roleArn: roleArn,
		appID:   appID,
		fetcher: &csiTokenFetcher{token: token},
	}, nil
}

func (p *IRSACredentialProvider) GetAWSConfig(ctx context.Context) (aws.Config, error) {
	stsClient := sts.New(sts.Options{Region: p.region})
	return config.LoadDefaultConfig(ctx,
		config.WithRegion(p.region),
		config.WithCredentialsProvider(stscreds.NewWebIdentityRoleProvider(stsClient, p.roleArn, p.fetcher)),
		config.WithAppID(p.appID),
	)
}
