package credential_provider

import (
	"context"
	"fmt"
	"strings"
	"time"

	"k8s.io/klog/v2"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/endpointcreds"

	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"

	"github.com/aws/secrets-store-csi-driver-provider-aws/utils"
)

const (
	podIdentityAudience = "pods.eks.amazonaws.com"
	defaultIPv4Endpoint = "http://169.254.170.23/v1/credentials"
	defaultIPv6Endpoint = "http://[fd00:ec2::23]/v1/credentials"
)

var (
	podIdentityAgentEndpointIPv4 = defaultIPv4Endpoint
	podIdentityAgentEndpointIPv6 = defaultIPv6Endpoint
)

// csiTokenProvider implements endpointcreds.AuthTokenProvider using pre-fetched CSI token
type csiTokenProvider struct {
	token string
}

func (p *csiTokenProvider) GetToken() (string, error) {
	return p.token, nil
}

// PodIdentityCredentialProvider implements ConfigProvider using EKS Pod Identity
type PodIdentityCredentialProvider struct {
	region               string
	preferredAddressType string
	appID                string
	fetcher              endpointcreds.AuthTokenProvider
	httpClient           *awshttp.BuildableClient
}

func NewPodIdentityCredentialProvider(
	region, preferredAddressType string,
	podIdentityHttpTimeout *time.Duration,
	appID, serviceAccountTokens string,
) (ConfigProvider, error) {
	if region == "" {
		return nil, fmt.Errorf("region cannot be empty")
	}

	token, err := utils.GetTokenForAudience(serviceAccountTokens, podIdentityAudience)
	if err != nil {
		klog.Errorf("Pod Identity authentication failed: could not get token for audience %q: %v", podIdentityAudience, err)
		return nil, fmt.Errorf("failed to get Pod Identity token: %w", err)
	}

	klog.Infof("Pod Identity token obtained for audience %q", podIdentityAudience)

	provider := &PodIdentityCredentialProvider{
		region:               region,
		preferredAddressType: preferredAddressType,
		appID:                appID,
		fetcher:              &csiTokenProvider{token: token},
	}

	if podIdentityHttpTimeout != nil {
		provider.httpClient = awshttp.NewBuildableClient().WithTimeout(*podIdentityHttpTimeout)
	}

	return provider, nil
}

func parseAddressPreference(preferredAddressType string) string {
	switch strings.ToLower(preferredAddressType) {
	case "", "auto":
		return "auto"
	case "ipv4":
		return "ipv4"
	case "ipv6":
		return "ipv6"
	default:
		return "auto" // Default to auto for invalid preferences
	}
}

func (p *PodIdentityCredentialProvider) GetAWSConfig(ctx context.Context) (aws.Config, error) {
	var configErr error
	preference := parseAddressPreference(p.preferredAddressType)

	if preference == "auto" || preference == "ipv4" {
		cfg, err := p.getConfigWithEndpoint(ctx, podIdentityAgentEndpointIPv4)
		if err != nil {
			klog.Warningf("IPv4 endpoint attempt failed: %v", err)
			configErr = err
		} else {
			return cfg, nil
		}
	}

	if preference == "auto" || preference == "ipv6" {
		cfg, err := p.getConfigWithEndpoint(ctx, podIdentityAgentEndpointIPv6)
		if err != nil {
			klog.Warningf("IPv6 endpoint attempt failed: %v", err)
			configErr = err
		} else {
			return cfg, nil
		}
	}

	return aws.Config{}, fmt.Errorf("failed to get AWS config from pod identity agent: %+v", configErr)
}

func (p *PodIdentityCredentialProvider) getConfigWithEndpoint(ctx context.Context, endpoint string) (aws.Config, error) {
	provider := endpointcreds.New(endpoint,
		func(opts *endpointcreds.Options) {
			opts.AuthorizationTokenProvider = p.fetcher
			if p.httpClient != nil {
				opts.HTTPClient = p.httpClient
			}
		},
	)
	return config.LoadDefaultConfig(ctx,
		config.WithCredentialsProvider(provider),
		config.WithRegion(p.region),
		config.WithAppID(p.appID),
	)
}
