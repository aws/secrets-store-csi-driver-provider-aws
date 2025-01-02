/*
 * Package responsible for returning an AWS SDK session with credentials
 * given an AWS region, K8s namespace, and K8s service account.
 *
 * This package requries that the K8s service account be associated with an IAM
 * role via IAM Roles for Service Accounts (IRSA).
 */
package auth

import (
	"context"
	"encoding/json"
	"fmt"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/credentials/stscreds"
	"github.com/aws/aws-sdk-go/aws/endpoints"
	"github.com/aws/aws-sdk-go/aws/request"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sts"
	"github.com/aws/aws-sdk-go/service/sts/stsiface"
	"io"
	"net/http"
	"time"

	authv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/klog/v2"
)

const (
	arnAnno                         = "eks.amazonaws.com/role-arn"
	docURL                          = "https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html"
	irsaAudience                    = "sts.amazonaws.com"
	podIdentityAudience             = "pods.eks.amazonaws.com"
	ProviderName                    = "secrets-store-csi-driver-provider-aws"
	defaultPodIdentityAgentEndpoint = "http://169.254.170.23/v1/credentials"
)

var podIdentityAgentEndpoint = defaultPodIdentityAgentEndpoint

// Private implementation of stscreds.TokenFetcher interface to fetch a token
// for use with AssumeRoleWithWebIdentity given a K8s namespace and service
// account.
type authTokenFetcher struct {
	nameSpace, svcAcc, podName string
	k8sClient                  k8sv1.CoreV1Interface
	usePodIdentity             bool
}

// Private helper to fetch a JWT token for a given namespace and service account.
//
// See also: https://pkg.go.dev/k8s.io/client-go/kubernetes/typed/core/v1
func (p authTokenFetcher) FetchToken(ctx credentials.Context) ([]byte, error) {
	var tokenSpec authv1.TokenRequestSpec

	if p.usePodIdentity {
		tokenSpec = authv1.TokenRequestSpec{
			Audiences: []string{podIdentityAudience},
			BoundObjectRef: &authv1.BoundObjectReference{
				Kind: "Pod",
				Name: p.podName,
			},
		}
	} else {
		tokenSpec = authv1.TokenRequestSpec{
			Audiences: []string{irsaAudience},
		}
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

// Auth is the main entry point to retrieve an AWS session. The caller
// initializes a new Auth object with NewAuth passing the region, namespace, pod name,
// K8s service account and usePodIdentity flag  (and request context). The caller can then obtain AWS
// sessions by calling GetAWSSession.
type Auth struct {
	region, nameSpace, svcAcc, podName string
	usePodIdentity                     bool
	k8sClient                          k8sv1.CoreV1Interface
	stsClient                          stsiface.STSAPI
	ctx                                context.Context
}

// Factory method to create a new Auth object for an incomming mount request.
func NewAuth(
	ctx context.Context,
	region, nameSpace, svcAcc, podName string,
	usePodIdentity bool,
	k8sClient k8sv1.CoreV1Interface,
) (auth *Auth, e error) {

	// Get an initial session to use for STS calls.
	sess, err := session.NewSession(aws.NewConfig().
		WithSTSRegionalEndpoint(endpoints.RegionalSTSEndpoint).
		WithRegion(region),
	)
	if err != nil {
		return nil, err
	}

	return &Auth{
		region:         region,
		nameSpace:      nameSpace,
		svcAcc:         svcAcc,
		podName:        podName,
		usePodIdentity: usePodIdentity,
		k8sClient:      k8sClient,
		stsClient:      sts.New(sess),
		ctx:            ctx,
	}, nil

}

// Private helper to lookup the role ARN for a given pod.
//
// This method looks up the role ARN associated with the K8s service account by
// calling the K8s APIs to get the role annotation on the service account.
// See also: https://pkg.go.dev/k8s.io/client-go/kubernetes/typed/core/v1
func (p Auth) getRoleARN() (arn *string, e error) {

	// cli equivalent: kubectl -o yaml -n <namespace> get serviceaccount <acct>
	rsp, err := p.k8sClient.ServiceAccounts(p.nameSpace).Get(p.ctx, p.svcAcc, metav1.GetOptions{})
	if err != nil {
		return nil, err
	}

	roleArn := rsp.Annotations[arnAnno]
	if len(roleArn) <= 0 {
		klog.Errorf("Need IAM role for service account %s (namespace: %s) - %s", p.svcAcc, p.nameSpace, docURL)
		return nil, fmt.Errorf("An IAM role must be associated with service account %s (namespace: %s)", p.svcAcc, p.nameSpace)
	}
	klog.Infof("Role ARN for %s:%s is %s", p.nameSpace, p.svcAcc, roleArn)

	return &roleArn, nil
}

// Get the AWS session credentials associated with a given pod's service account.
//
// The returned session is capable of automatically refreshing creds as needed
// by using a private TokenFetcher helper.
func (p Auth) GetAWSSession() (awsSession *session.Session, e error) {
	var config *aws.Config

	fetcher := &authTokenFetcher{p.nameSpace, p.svcAcc, p.podName, p.k8sClient, p.usePodIdentity}

	if p.usePodIdentity {

		// Get token for Pod Identity
		token, err := fetcher.FetchToken(context.Background())
		if err != nil {
			return nil, fmt.Errorf("failed to fetch token: %+v", err)
		}

		config, err = p.getCredentialsFromPodIdentityAgent(token)
		if err != nil {
			return nil, err
		}
	} else {
		roleArn, err := p.getRoleARN()
		if err != nil {
			return nil, err
		}
		ar := stscreds.NewWebIdentityRoleProviderWithToken(p.stsClient, *roleArn, ProviderName, fetcher)
		config = aws.NewConfig().
			WithSTSRegionalEndpoint(endpoints.RegionalSTSEndpoint). // Use regional STS endpoint
			WithRegion(p.region).
			WithCredentials(credentials.NewCredentials(ar))
	}

	// Include the provider in the user agent string.
	sess, err := session.NewSession(config)
	if err != nil {
		return nil, err
	}
	sess.Handlers.Build.PushFront(func(r *request.Request) {
		request.AddToUserAgent(r, ProviderName)
	})

	return session.Must(sess, err), nil
}

// Private helper to fetch temporary AWS credentials from Pod Identity Agent
func (p Auth) getCredentialsFromPodIdentityAgent(token []byte) (awsConfig *aws.Config, e error) {
	client := &http.Client{Timeout: 5 * time.Second}
	req, err := http.NewRequest("GET", podIdentityAgentEndpoint, nil)
	if err != nil {
		return nil, fmt.Errorf("failed to create HTTP request to pod identity agent: %+v", err)
	}
	req.Header.Set("Authorization", string(token))
	resp, err := client.Do(req)
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
