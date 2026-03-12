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
	authv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
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

type podIdentityTokenFetcher struct {
	nameSpace, svcAcc, podName string
	k8sClient                  k8sv1.CoreV1Interface
}

func newPodIdentityTokenFetcher(
	nameSpace, svcAcc, podName string,
	k8sClient k8sv1.CoreV1Interface,
) endpointcreds.AuthTokenProvider {
	return &podIdentityTokenFetcher{
		nameSpace: nameSpace,
		svcAcc:    svcAcc,
		podName:   podName,
		k8sClient: k8sClient,
	}
}

func (p *podIdentityTokenFetcher) GetToken() (string, error) {
	tokenSpec := authv1.TokenRequestSpec{
		Audiences: []string{podIdentityAudience},
		BoundObjectRef: &authv1.BoundObjectReference{
			Kind: "Pod",
			Name: p.podName,
		},
	}

	// Use the K8s API to fetch the token associated with service account
	tokRsp, err := p.k8sClient.ServiceAccounts(p.nameSpace).CreateToken(
		context.Background(),
		p.svcAcc,
		&authv1.TokenRequest{Spec: tokenSpec},
		metav1.CreateOptions{})
	if err != nil {
		return "", err
	}

	return tokRsp.Status.Token, nil
}

// PodIdentityCredentialProvider implements CredentialProvider using pod identity
type PodIdentityCredentialProvider struct {
	region               string
	preferredAddressType string
	appID                string
	fetcher              endpointcreds.AuthTokenProvider
	httpClient           *awshttp.BuildableClient
}

func NewPodIdentityCredentialProvider(
	region, nameSpace, svcAcc, podName, preferredAddressType string,
	podIdentityHttpTimeout *time.Duration,
	appID string,
	k8sClient k8sv1.CoreV1Interface,
) (ConfigProvider, error) {
	if region == "" {
		return nil, fmt.Errorf("region cannot be empty")
	}
	if k8sClient == nil {
		return nil, fmt.Errorf("k8s client cannot be nil")
	}

	pod_identity := PodIdentityCredentialProvider{
		region:               region,
		preferredAddressType: preferredAddressType,
		appID:                appID,
		fetcher:              newPodIdentityTokenFetcher(nameSpace, svcAcc, podName, k8sClient),
	}

	if podIdentityHttpTimeout != nil {
		pod_identity.httpClient = awshttp.NewBuildableClient().WithTimeout(*podIdentityHttpTimeout)
	}

	return &pod_identity, nil
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
		config, err := p.getConfigWithEndpoint(ctx, podIdentityAgentEndpointIPv4)
		if err != nil {
			klog.Warningf("IPv4 endpoint attempt failed: %v", err)
			configErr = err
		} else {
			return config, nil
		}
	}

	if preference == "auto" || preference == "ipv6" {
		config, err := p.getConfigWithEndpoint(ctx, podIdentityAgentEndpointIPv6)

		if err != nil {
			klog.Warningf("IPv6 endpoint attempt failed: %v", err)
			configErr = err
		} else {
			return config, nil
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
