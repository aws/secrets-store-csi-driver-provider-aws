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
	"net"
	"net/http"
	"os"
	"time"
)

const (
	podIdentityAudience          = "pods.eks.amazonaws.com"
	podIdentityAgentEndpointIPv4 = "http://169.254.170.23/v1/credentials"
	podIdentityAgentEndpointIPv6 = "http://[fd00:ec2::23]/v1/credentials"
	httpTimeout                  = 5 * time.Second
	podIdentityAuthHeader        = "Authorization"
)

// defaultPodIdentityAgentEndpoint determines the appropriate EKS Pod Identity Agent endpoint based on IP version
var defaultPodIdentityAgentEndpoint = func() string {
	isIPv6, err := isIPv6()
	if err != nil {
		klog.Warningf("Error determining IP version: %v. Defaulting to IPv4 endpoint", err)
		return podIdentityAgentEndpointIPv4
	}

	if isIPv6 {
		klog.Infof("Using Pod Identity Agent IPv6 endpoint")
		return podIdentityAgentEndpointIPv6
	}
	klog.Infof("Using Pod Identity Agent IPv4 endpoint")
	return podIdentityAgentEndpointIPv4
}()

var podIdentityAgentEndpoint = defaultPodIdentityAgentEndpoint

// PodIdentityCredentialProvider implements CredentialProvider using pod identity
type PodIdentityCredentialProvider struct {
	region     string
	fetcher    authTokenFetcher
	httpClient *http.Client
}

func NewPodIdentityCredentialProvider(
	region, nameSpace, svcAcc, podName string,
	k8sClient k8sv1.CoreV1Interface,
) CredentialProvider {
	return &PodIdentityCredentialProvider{
		region:  region,
		fetcher: newPodIdentityTokenFetcher(nameSpace, svcAcc, podName, k8sClient),
		httpClient: &http.Client{
			Timeout: httpTimeout,
		},
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

	// Use the K8s API to fetch the token from the OIDC provider.
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

func isIPv6() (isIPv6 bool, err error) {
	podIP := os.Getenv("POD_IP")
	if podIP == "" {
		return false, fmt.Errorf("POD_IP environment variable is not set")
	}

	parsedIP := net.ParseIP(podIP)
	if parsedIP == nil {
		return false, fmt.Errorf("invalid IP address format in POD_IP: %s", podIP)
	}

	isIPv6 = parsedIP.To4() == nil
	klog.Infof("Pod IP %s is IPv%d", podIP, map[bool]int{false: 4, true: 6}[isIPv6])

	return isIPv6, nil
}
