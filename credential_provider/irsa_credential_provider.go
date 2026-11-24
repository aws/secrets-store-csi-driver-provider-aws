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

// IRSACredentialProvider implements CredentialProvider using IAM Roles for Service Accounts
type IRSACredentialProvider struct {
	region  string
	roleArn string
	appID   string
	fetcher stscreds.IdentityTokenRetriever

	stsOptions []func(*sts.Options)
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
	cfg, err := config.LoadDefaultConfig(ctx,
		config.WithRegion(p.region),
		config.WithAppID(p.appID),
		// The unsigned STS token exchange can skip the default credential chain.
		config.WithCredentialsProvider(aws.AnonymousCredentials{}),
	)
	if err != nil {
		return aws.Config{}, err
	}

	stsClient := sts.NewFromConfig(cfg, p.stsOptions...)
	provider := stscreds.NewWebIdentityRoleProvider(stsClient, p.roleArn, p.fetcher)
	cfg.Credentials = aws.NewCredentialsCache(provider)
	return cfg, nil
}
