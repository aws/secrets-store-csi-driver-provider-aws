package credential_provider

import (
	"context"
	"fmt"
	"strings"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/endpointcreds"

	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"k8s.io/klog/v2"
)

const (
	defaultIPv4Endpoint = "http://169.254.170.23/v1/credentials"
	defaultIPv6Endpoint = "http://[fd00:ec2::23]/v1/credentials"
)

var (
	podIdentityAgentEndpointIPv4 = defaultIPv4Endpoint
	podIdentityAgentEndpointIPv6 = defaultIPv6Endpoint
)

// csiTokenProvider implements endpointcreds.AuthTokenProvider using a pre-fetched CSI token.
type csiTokenProvider struct {
	token string
}

func (p *csiTokenProvider) GetToken() (string, error) {
	return p.token, nil
}

// PodIdentityCredentialProvider implements ConfigProvider using EKS Pod Identity.
type PodIdentityCredentialProvider struct {
	region               string
	preferredAddressType string
	appID                string
	fetcher              endpointcreds.AuthTokenProvider
	httpClient           *awshttp.BuildableClient
}

// NewPodIdentityCredentialProvider creates a credential provider for EKS Pod Identity.
// Callers must ensure region and token are non-empty.
func NewPodIdentityCredentialProvider(
	region, preferredAddressType string,
	podIdentityHttpTimeout *time.Duration,
	appID, token string,
) (ConfigProvider, error) {
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
		return "auto"
	}
}

// GetAWSConfig attempts to connect to the Pod Identity Agent, trying endpoints
// based on the preferred address type (IPv4 first by default, with IPv6 fallback).
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
