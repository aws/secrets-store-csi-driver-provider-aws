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
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/endpoints"
	"github.com/aws/aws-sdk-go/aws/request"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/sts"
	"github.com/aws/aws-sdk-go/service/sts/stsiface"
	"github.com/aws/secrets-store-csi-driver-provider-aws/credential_provider"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/klog/v2"
)

const (
	ProviderName = "secrets-store-csi-driver-provider-aws"
)

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

// Get the AWS session credentials associated with a given pod's service account.
//
// The returned session is capable of automatically refreshing creds as needed
// by using a private TokenFetcher helper.
func (p Auth) GetAWSSession() (awsSession *session.Session, e error) {
	var credProvider credential_provider.CredentialProvider

	if p.usePodIdentity {
		klog.Infof("Using Pod Identity for authentication in namespace: %s, service account: %s", p.nameSpace, p.svcAcc)
		credProvider = credential_provider.NewPodIdentityCredentialProvider(p.region, p.nameSpace, p.svcAcc, p.podName, p.k8sClient)
	} else {
		klog.Infof("Using IAM Roles for Service Accounts for authentication in namespace: %s, service account: %s", p.nameSpace, p.svcAcc)
		credProvider = credential_provider.NewIRSACredentialProvider(p.stsClient, p.region, p.nameSpace, p.svcAcc, p.k8sClient, p.ctx)
	}

	config, err := credProvider.GetAWSConfig()
	if err != nil {
		return nil, err
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
