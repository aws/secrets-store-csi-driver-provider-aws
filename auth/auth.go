/*
 * Package responsible for returning an AWS SDK config with credentials
 * given an AWS region, K8s namespace, and K8s service account.
 *
 * This package requries that the K8s service account be associated with an IAM
 * role via IAM Roles for Service Accounts (IRSA).
 */
package auth

import (
	"context"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/secrets-store-csi-driver-provider-aws/credential_provider"
	"github.com/aws/smithy-go/middleware"

	smithyhttp "github.com/aws/smithy-go/transport/http"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/klog/v2"
)

const (
	ProviderName = "secrets-store-csi-driver-provider-aws"
)

// ProviderVersion is injected at build time from the Makefile
var ProviderVersion = "unknown"

// irsaAuth implements credential_provider.ConfigProvider using IAM Roles for Service Accounts
type irsaAuth struct {
	region, namespace, serviceAccount string
	k8sClient                         k8sv1.CoreV1Interface
	stsClient                         stscreds.AssumeRoleWithWebIdentityAPIClient
	tokenFetcher                      credential_provider.TokenFetcher
}

// NewIRSAAuth creates a ConfigProvider that uses IAM Roles for Service Accounts authentication.
func NewIRSAAuth(
	region, namespace, serviceAccount string,
	k8sClient k8sv1.CoreV1Interface,
	tokenFetcher credential_provider.TokenFetcher,
) (credential_provider.ConfigProvider, error) {
	klog.Infof("Using IAM Roles for Service Accounts for authentication in namespace: %s, service account: %s", namespace, serviceAccount)

	// Get an initial config to use for STS calls when using IRSA
	cfg, err := config.LoadDefaultConfig(context.Background(),
		config.WithRegion(region),
		config.WithDefaultsMode(aws.DefaultsModeStandard),
	)
	if err != nil {
		return nil, err
	}

	stsClient := sts.NewFromConfig(cfg)

	return &irsaAuth{
		region:         region,
		namespace:      namespace,
		serviceAccount: serviceAccount,
		k8sClient:      k8sClient,
		stsClient:      stsClient,
		tokenFetcher:   tokenFetcher,
	}, nil
}

// GetAWSConfig for IRSA auth
func (p *irsaAuth) GetAWSConfig(ctx context.Context) (aws.Config, error) {
	credProvider := credential_provider.NewIRSACredentialProvider(
		p.region,
		p.namespace,
		p.serviceAccount,
		p.stsClient,
		p.k8sClient,
		p.tokenFetcher,
	)

	cfg, err := credProvider.GetAWSConfig(ctx)
	if err != nil {
		return aws.Config{}, err
	}

	cfg.APIOptions = append(cfg.APIOptions, func(stack *middleware.Stack) error {
		return stack.Build.Add(&userAgentMiddleware{
			providerName: ProviderName,
		}, middleware.After)
	})

	return cfg, nil
}

// podIdentityAuth implements credential_provider.ConfigProvider using Pod Identity
type podIdentityAuth struct {
	region, preferredAddressType string
	tokenFetcher                 credential_provider.TokenFetcher
}

// NewPodIdentityAuth creates a ConfigProvider that uses Pod Identity authentication.
func NewPodIdentityAuth(
	region, preferredAddressType string,
	tokenFetcher credential_provider.TokenFetcher,
) (credential_provider.ConfigProvider, error) {
	return &podIdentityAuth{
		region:               region,
		preferredAddressType: preferredAddressType,
		tokenFetcher:         tokenFetcher,
	}, nil
}

// GetAWSConfig for Pod Identity auth
func (p *podIdentityAuth) GetAWSConfig(ctx context.Context) (aws.Config, error) {
	credProvider, err := credential_provider.NewPodIdentityCredentialProvider(
		p.region,
		p.preferredAddressType,
		p.tokenFetcher,
	)
	if err != nil {
		return aws.Config{}, err
	}

	cfg, err := credProvider.GetAWSConfig(ctx)
	if err != nil {
		return aws.Config{}, err
	}

	cfg.APIOptions = append(cfg.APIOptions, func(stack *middleware.Stack) error {
		return stack.Build.Add(&userAgentMiddleware{
			providerName: ProviderName,
		}, middleware.After)
	})

	return cfg, nil
}

type userAgentMiddleware struct {
	providerName string
}

func (m *userAgentMiddleware) ID() string {
	return "UserAgent"
}

func (m *userAgentMiddleware) HandleBuild(ctx context.Context, in middleware.BuildInput, next middleware.BuildHandler) (
	out middleware.BuildOutput, metadata middleware.Metadata, err error) {
	req, ok := in.Request.(*smithyhttp.Request)
	if !ok {
		return next.HandleBuild(ctx, in)
	}
	req.Header.Add("User-Agent", m.providerName+"/"+ProviderVersion)
	return next.HandleBuild(ctx, in)
}
