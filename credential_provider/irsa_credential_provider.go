package credential_provider

import (
	"context"
	"fmt"
	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/credentials"
	"github.com/aws/aws-sdk-go/aws/credentials/stscreds"
	"github.com/aws/aws-sdk-go/aws/endpoints"
	"github.com/aws/aws-sdk-go/service/sts/stsiface"
	authv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/klog/v2"
)

const (
	arnAnno      = "eks.amazonaws.com/role-arn"
	docURL       = "https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html"
	irsaAudience = "sts.amazonaws.com"
	ProviderName = "secrets-store-csi-driver-provider-aws"
)

// IRSACredentialProvider implements CredentialProvider using IAM Roles for Service Accounts
type IRSACredentialProvider struct {
	stsClient                 stsiface.STSAPI
	k8sClient                 k8sv1.CoreV1Interface
	region, nameSpace, svcAcc string
	fetcher                   authTokenFetcher
	ctx                       context.Context
}

func NewIRSACredentialProvider(
	stsClient stsiface.STSAPI,
	region, nameSpace, svcAcc string,
	k8sClient k8sv1.CoreV1Interface,
	ctx context.Context,
) CredentialProvider {
	return &IRSACredentialProvider{
		stsClient: stsClient,
		k8sClient: k8sClient,
		region:    region,
		nameSpace: nameSpace,
		svcAcc:    svcAcc,
		fetcher:   newIRSATokenFetcher(nameSpace, svcAcc, k8sClient),
		ctx:       ctx,
	}
}

func (p *IRSACredentialProvider) GetAWSConfig() (*aws.Config, error) {
	roleArn, err := p.getRoleARN()
	if err != nil {
		return nil, err
	}
	ar := stscreds.NewWebIdentityRoleProviderWithToken(
		p.stsClient,
		*roleArn,
		ProviderName,
		p.fetcher,
	)

	return aws.NewConfig().
		WithSTSRegionalEndpoint(endpoints.RegionalSTSEndpoint).
		WithRegion(p.region).
		WithCredentials(credentials.NewCredentials(ar)), nil
}

type irsaTokenFetcher struct {
	nameSpace, svcAcc string
	k8sClient         k8sv1.CoreV1Interface
}

func newIRSATokenFetcher(
	nameSpace, svcAcct string,
	k8sClient k8sv1.CoreV1Interface,
) authTokenFetcher {
	return &irsaTokenFetcher{
		nameSpace: nameSpace,
		svcAcc:    svcAcct,
		k8sClient: k8sClient,
	}
}

// Private helper to fetch a JWT token for a given namespace and service account.
//
// See also: https://pkg.go.dev/k8s.io/client-go/kubernetes/typed/core/v1
func (p *irsaTokenFetcher) FetchToken(ctx credentials.Context) ([]byte, error) {
	tokenSpec := authv1.TokenRequestSpec{
		Audiences: []string{irsaAudience},
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

// Private helper to lookup the role ARN for a given pod.
//
// This method looks up the role ARN associated with the K8s service account by
// calling the K8s APIs to get the role annotation on the service account.
// See also: https://pkg.go.dev/k8s.io/client-go/kubernetes/typed/core/v1
func (p IRSACredentialProvider) getRoleARN() (arn *string, e error) {

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
