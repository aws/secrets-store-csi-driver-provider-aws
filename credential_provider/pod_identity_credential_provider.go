package credential_provider

import (
	"context"
	"net/http"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/endpointcreds"
)

const (
	defaultIPv4Endpoint = "http://169.254.170.23/v1/credentials"
	defaultIPv6Endpoint = "http://[fd00:ec2::23]/v1/credentials"
	httpTimeout         = 100 * time.Millisecond
)

var (
	podIdentityAgentEndpointIPv4 = defaultIPv4Endpoint
	podIdentityAgentEndpointIPv6 = defaultIPv6Endpoint
)

// PodIdentityCredentialProvider implements CredentialProvider using pod identity
type PodIdentityCredentialProvider struct {
	region, credentialEndpoint string
	fetcher                    endpointcreds.AuthTokenProvider
	httpClient                 *http.Client
}

func NewPodIdentityCredentialProvider(
	region, preferredAddressType string,
	tokenFetcher TokenFetcher,
) (ConfigProvider, error) {
	endpoint := podIdentityAgentEndpointIPv4
	if preferredAddressType == "ipv6" {
		endpoint = podIdentityAgentEndpointIPv6
	}

	return &PodIdentityCredentialProvider{
		region:             region,
		credentialEndpoint: endpoint,
		fetcher:            tokenFetcher,
		httpClient: &http.Client{
			Timeout: httpTimeout,
		},
	}, nil
}

func (p *PodIdentityCredentialProvider) GetAWSConfig(ctx context.Context) (aws.Config, error) {
	provider := endpointcreds.New(p.credentialEndpoint,
		func(opts *endpointcreds.Options) {
			opts.AuthorizationTokenProvider = p.fetcher
			opts.HTTPClient = p.httpClient
		},
	)
	return config.LoadDefaultConfig(ctx,
		config.WithCredentialsProvider(provider),
		config.WithRegion(p.region),
	)
}
