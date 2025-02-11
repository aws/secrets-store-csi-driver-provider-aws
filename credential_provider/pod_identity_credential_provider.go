package credential_provider

import (
	"context"
	"net/http"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/endpointcreds"
	authv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
)

const (
	podIdentityAudience = "pods.eks.amazonaws.com"
	defaultIPv4Endpoint = "http://169.254.170.23/v1/credentials"
	defaultIPv6Endpoint = "http://[fd00:ec2::23]/v1/credentials"
	httpTimeout         = 100 * time.Millisecond
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

// validate the podIdentityTokenFetcher implements the endpointcreds.AuthTokenProvider interface
var _ endpointcreds.AuthTokenProvider = &podIdentityTokenFetcher{}

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
	region             string
	credentialEndpoint string
	fetcher            endpointcreds.AuthTokenProvider
	httpClient         *http.Client
}

func NewPodIdentityCredentialProvider(
	region, nameSpace, svcAcc, podName, preferredAddressType string,
	k8sClient k8sv1.CoreV1Interface,
) (ConfigProvider, error) {

	endpoint := podIdentityAgentEndpointIPv4
	if preferredAddressType == "ipv6" {
		endpoint = podIdentityAgentEndpointIPv6
	}

	return &PodIdentityCredentialProvider{
		region:             region,
		credentialEndpoint: endpoint,
		fetcher:            newPodIdentityTokenFetcher(nameSpace, svcAcc, podName, k8sClient),
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
