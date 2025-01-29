package credential_provider

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"io"
	authv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/klog/v2"
	"net/http"
	"strings"
	"time"
)

const (
	podIdentityAudience   = "pods.eks.amazonaws.com"
	defaultIPv4Endpoint   = "http://169.254.170.23/v1/credentials"
	defaultIPv6Endpoint   = "http://[fd00:ec2::23]/v1/credentials"
	httpTimeout           = 100 * time.Millisecond
	podIdentityAuthHeader = "Authorization"
)

var (
	podIdentityAgentEndpointIPv4 = defaultIPv4Endpoint
	podIdentityAgentEndpointIPv6 = defaultIPv6Endpoint
)

// endpointPreference represents the preferred IP address type for Pod Identity Agent endpoint
type endpointPreference int

const (
	// preferenceAuto indicates automatic endpoint selection, trying IPv4 first and falling back to IPv6 if IPv4 fails
	preferenceAuto endpointPreference = iota

	// preferenceIPv4 forces the use of Pod Identity Agent IPv4 endpoint
	preferenceIPv4

	// preferenceIPv6 forces the use of Pod Identity Agent IPv6 endpoint
	preferenceIPv6
)

// PodIdentityCredentialProvider implements CredentialProvider using pod identity
type PodIdentityCredentialProvider struct {
	region            string
	preferredEndpoint endpointPreference
	fetcher           authTokenFetcher
	httpClient        *http.Client
}

func NewPodIdentityCredentialProvider(
	region, nameSpace, svcAcc, podName, preferredAddressType string,
	k8sClient k8sv1.CoreV1Interface,
) CredentialProvider {

	preferredEndpoint := parseAddressPreference(preferredAddressType)
	return &PodIdentityCredentialProvider{
		region:            region,
		preferredEndpoint: preferredEndpoint,
		fetcher:           newPodIdentityTokenFetcher(nameSpace, svcAcc, podName, k8sClient),
		httpClient: &http.Client{
			Timeout: httpTimeout,
		},
	}
}

// parseAddressPreference converts the provided preferred address type string into an endpointPreference.
func parseAddressPreference(preferredAddressType string) endpointPreference {
	switch strings.ToLower(preferredAddressType) {
	case "ipv4":
		return preferenceIPv4
	case "ipv6":
		return preferenceIPv6
	default:
		if preferredAddressType != "" {
			klog.Warningf("Unknown preferred address type: %s, falling back to auto selection", preferredAddressType)
		}
		return preferenceAuto
	}
}

type podIdentityTokenFetcher struct {
	nameSpace, svcAcc, podName string
	k8sClient                  k8sv1.CoreV1Interface
}

func newPodIdentityTokenFetcher(
	nameSpace, svcAcc, podName string,
	k8sClient k8sv1.CoreV1Interface,
) authTokenFetcher {
	return &podIdentityTokenFetcher{
		nameSpace: nameSpace,
		svcAcc:    svcAcc,
		podName:   podName,
		k8sClient: k8sClient,
	}
}

// Private helper to fetch a JWT token for a given namespace and service account.
//
// See also: https://pkg.go.dev/k8s.io/client-go/kubernetes/typed/core/v1
func (p *podIdentityTokenFetcher) FetchToken(ctx credentials.Context) ([]byte, error) {

	tokenSpec := authv1.TokenRequestSpec{
		Audiences: []string{podIdentityAudience},
		BoundObjectRef: &authv1.BoundObjectReference{
			Kind: "Pod",
			Name: p.podName,
		},
	}

	// Use the K8s API to fetch the token associated with service account
	tokRsp, err := p.k8sClient.ServiceAccounts(p.nameSpace).CreateToken(ctx, p.svcAcc, &authv1.TokenRequest{
		Spec: tokenSpec,
	}, metav1.CreateOptions{})
	if err != nil {
		return nil, err
	}

	return []byte(tokRsp.Status.Token), nil
}

func (p *PodIdentityCredentialProvider) GetAWSConfig() (*aws.Config, error) {
	// Get token for Pod Identity
	token, err := p.fetcher.FetchToken(context.Background())
	if err != nil {
		return nil, fmt.Errorf("failed to fetch token: %+v", err)
	}

	switch p.preferredEndpoint {
	case preferenceIPv4:
		klog.Infof("Using preferred Pod Identity Agent IPv4 endpoint")
		config, err := p.getAWSConfigFromPodIdentityAgent(token, podIdentityAgentEndpointIPv4)
		if err != nil {
			return nil, fmt.Errorf("failed to get AWS config from pod identity agent IPv4 endpoint: %+v", err)
		}
		return config, nil
	case preferenceIPv6:
		klog.Infof("Using preferred Pod Identity Agent IPv6 endpoint")
		config, err := p.getAWSConfigFromPodIdentityAgent(token, podIdentityAgentEndpointIPv6)
		if err != nil {
			return nil, fmt.Errorf("failed to get AWS config from pod identity agent IPv6 endpoint: %+v", err)
		}
		return config, nil
	default:
		klog.Infof("Using auto Pod Identity Agent endpoint selection")
		config, err := p.getAWSConfigFromPodIdentityAgent(token, podIdentityAgentEndpointIPv4)
		if err != nil {
			klog.Warningf("IPv4 endpoint attempt failed: %+v. Trying IPv6 endpoint", err)
			config, err = p.getAWSConfigFromPodIdentityAgent(token, podIdentityAgentEndpointIPv6)
			if err != nil {
				return nil, fmt.Errorf("failed to get AWS config from pod identity agent: %+v", err)
			}
		}
		return config, nil
	}
}

func (p *PodIdentityCredentialProvider) getAWSConfigFromPodIdentityAgent(token []byte, podIdentityAgentEndpoint string) (*aws.Config, error) {
	req, err := http.NewRequest("GET", podIdentityAgentEndpoint, nil)
	if err != nil {

		return nil, fmt.Errorf("failed to create HTTP request to pod identity agent: %+v", err)
	}
	req.Header.Set(podIdentityAuthHeader, string(token))
	resp, err := p.httpClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("HTTP request to pod identity agent failed: %+v", err)
	}

	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		// Read the response body
		body, err := io.ReadAll(resp.Body)
		if err != nil {
			return nil, fmt.Errorf("failed to read error response body: %v, status code: %d", err, resp.StatusCode)
		}

		return nil, fmt.Errorf("pod identity agent returned error - Status: %d, Headers: %v, Body: %s",
			resp.StatusCode,
			resp.Header,
			string(body))
	}

	var creds struct {
		AccessKeyId     string `json:"AccessKeyId"`
		SecretAccessKey string `json:"SecretAccessKey"`
		Token           string `json:"Token"`
	}

	if err := json.NewDecoder(resp.Body).Decode(&creds); err != nil {
		return nil, fmt.Errorf("failed to decode credentials from pod identity agent: %+v", err)
	}

	if creds.AccessKeyId == "" || creds.SecretAccessKey == "" || creds.Token == "" {
		return nil, fmt.Errorf("received invalid credentials from pod identity agent")
	}

	return aws.NewConfig().
		WithRegion(p.region).
		WithCredentials(credentials.NewStaticCredentials(
			creds.AccessKeyId,
			creds.SecretAccessKey,
			creds.Token,
		)), nil
}
