package credential_provider

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"k8s.io/klog/v2"
)

const (
	docURL = "https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html"
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
	stsClient stscreds.AssumeRoleWithWebIdentityAPIClient
	region    string
	roleArn   string
	appID     string
	fetcher   stscreds.IdentityTokenRetriever
}

func NewIRSACredentialProvider(
	stsClient stscreds.AssumeRoleWithWebIdentityAPIClient,
	region, roleArn, appID, token string,
) (ConfigProvider, error) {
	if region == "" {
		return nil, fmt.Errorf("region cannot be empty")
	}
	if roleArn == "" {
		klog.Errorf("IRSA authentication failed: no IAM role ARN found on service account")
		return nil, fmt.Errorf("IAM role ARN is required for IRSA - %s", docURL)
	}
	if token == "" {
		return nil, fmt.Errorf("IRSA token cannot be empty")
	}

	return &IRSACredentialProvider{
		stsClient: stsClient,
		region:    region,
		roleArn:   roleArn,
		appID:     appID,
		fetcher:   &csiTokenFetcher{token: token},
	}, nil
}

func (p *IRSACredentialProvider) GetAWSConfig(ctx context.Context) (aws.Config, error) {
	return config.LoadDefaultConfig(ctx,
		config.WithRegion(p.region),
		config.WithCredentialsProvider(stscreds.NewWebIdentityRoleProvider(p.stsClient, p.roleArn, p.fetcher)),
		config.WithAppID(p.appID),
	)
}
