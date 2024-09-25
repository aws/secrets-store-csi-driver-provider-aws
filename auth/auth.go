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
	"fmt"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/credentials/stscreds"
	"github.com/aws/aws-sdk-go/aws/endpoints"
	"github.com/aws/aws-sdk-go/aws/request"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sts"
	"github.com/aws/aws-sdk-go/service/sts/stsiface"
	"github.com/aws/secrets-store-csi-driver-provider-aws/utils"

	authv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/klog/v2"
)

const (
	arnAnno       = "eks.amazonaws.com/role-arn"
	docURL        = "https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html"
	tokenAudience = "sts.amazonaws.com"
	ProviderName  = "secrets-store-csi-driver-provider-aws"
)

// Private implementation of stscreds.TokenFetcher interface to fetch a token
// for use with AssumeRoleWithWebIdentity given a K8s namespace and service
// account.
//
type authTokenFetcher struct {
	nameSpace, svcAcc string
	k8sClient         k8sv1.CoreV1Interface
}

// Private helper to fetch a JWT token for a given namespace and service account.
//
// See also: https://pkg.go.dev/k8s.io/client-go/kubernetes/typed/core/v1
//
func (p authTokenFetcher) FetchToken(ctx credentials.Context) ([]byte, error) {

	// Use the K8s API to fetch the token from the OIDC provider.
	tokRsp, err := p.k8sClient.ServiceAccounts(p.nameSpace).CreateToken(ctx, p.svcAcc, &authv1.TokenRequest{
		Spec: authv1.TokenRequestSpec{
			Audiences: []string{tokenAudience},
		},
	}, metav1.CreateOptions{})
	if err != nil {
		return nil, err
	}

	return []byte(tokRsp.Status.Token), nil
}

// Auth is the main entry point to retrive an AWS session. The caller
// initializes a new Auth object with NewAuth passing the region, namespace, and
// K8s service account (and request context). The caller can then obtain AWS
// sessions by calling GetAWSSession.
//
type Auth struct {
	region, nameSpace, svcAcc string
	k8sClient                 k8sv1.CoreV1Interface
	stsClient                 stsiface.STSAPI
	ctx                       context.Context
}

// Factory method to create a new Auth object for an incomming mount request.
//
func NewAuth(
	ctx context.Context,
	region, nameSpace, svcAcc string,
	k8sClient k8sv1.CoreV1Interface,
) (auth *Auth, e error) {

	// Get an initial session to use for STS calls.
	sess, err := session.NewSession(aws.NewConfig().
		WithEndpointResolver(utils.EnvironmentEndpointResolver()).
		WithSTSRegionalEndpoint(endpoints.RegionalSTSEndpoint).
		WithRegion(region),
	)
	if err != nil {
		return nil, err
	}

	return &Auth{
		region:    region,
		nameSpace: nameSpace,
		svcAcc:    svcAcc,
		k8sClient: k8sClient,
		stsClient: sts.New(sess),
		ctx:       ctx,
	}, nil

}

// Private helper to lookup the role ARN for a given pod.
//
// This method looks up the role ARN associated with the K8s service account by
// calling the K8s APIs to get the role annotation on the service account.
// See also: https://pkg.go.dev/k8s.io/client-go/kubernetes/typed/core/v1
//
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
//
func (p Auth) GetAWSSession() (awsSession *session.Session, e error) {

	roleArn, err := p.getRoleARN()
	if err != nil {
		return nil, err
	}

	fetcher := &authTokenFetcher{p.nameSpace, p.svcAcc, p.k8sClient}
	ar := stscreds.NewWebIdentityRoleProviderWithToken(p.stsClient, *roleArn, ProviderName, fetcher)
	config := aws.NewConfig().
		WithEndpointResolver(utils.EnvironmentEndpointResolver()).
		WithSTSRegionalEndpoint(endpoints.RegionalSTSEndpoint). // Use regional STS endpoint
		WithRegion(p.region).
		WithCredentials(credentials.NewCredentials(ar))

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
