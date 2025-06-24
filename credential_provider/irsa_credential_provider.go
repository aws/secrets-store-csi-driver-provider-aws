package credential_provider

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/klog/v2"
)

const (
	arnAnno = "eks.amazonaws.com/role-arn"
	docURL  = "https://docs.aws.amazon.com/eks/latest/userguide/iam-roles-for-service-accounts.html"
)

// IRSACredentialProvider implements CredentialProvider using IAM Roles for Service Accounts
type IRSACredentialProvider struct {
	region, nameSpace, svcAcc string
	stsClient                 stscreds.AssumeRoleWithWebIdentityAPIClient
	k8sClient                 k8sv1.CoreV1Interface
	fetcher                   stscreds.IdentityTokenRetriever
}

func NewIRSACredentialProvider(
	region, nameSpace, svcAcc string,
	stsClient stscreds.AssumeRoleWithWebIdentityAPIClient,
	k8sClient k8sv1.CoreV1Interface,
	tokenFetcher TokenFetcher,
) ConfigProvider {
	return &IRSACredentialProvider{
		region:    region,
		nameSpace: nameSpace,
		svcAcc:    svcAcc,
		stsClient: stsClient,
		k8sClient: k8sClient,
		fetcher:   tokenFetcher,
	}
}

func (p *IRSACredentialProvider) GetAWSConfig(ctx context.Context) (aws.Config, error) {
	roleArn, err := p.getRoleARN(ctx)
	if err != nil {
		return aws.Config{}, err
	}

	// Load the default config with our custom credentials provider
	return config.LoadDefaultConfig(ctx,
		config.WithRegion(p.region),
		config.WithCredentialsProvider(stscreds.NewWebIdentityRoleProvider(p.stsClient, *roleArn, p.fetcher)),
	)
}

// Private helper to lookup the role ARN for a given pod.
// This method looks up the role ARN associated with the K8s service account by
// calling the K8s APIs to get the role annotation on the service account.
// See also: https://pkg.go.dev/k8s.io/client-go/kubernetes/typed/core/v1
func (p *IRSACredentialProvider) getRoleARN(ctx context.Context) (arn *string, e error) {
	rsp, err := p.k8sClient.ServiceAccounts(p.nameSpace).Get(ctx, p.svcAcc, metav1.GetOptions{})
	if err != nil {
		return nil, err
	}

	roleArn := rsp.Annotations[arnAnno]
	if len(roleArn) <= 0 {
		klog.Errorf("need IAM role for service account %s (namespace: %s) - %s", p.svcAcc, p.nameSpace, docURL)
		return nil, fmt.Errorf("an IAM role must be associated with service account %s (namespace: %s)", p.svcAcc, p.nameSpace)
	}
	klog.Infof("Role ARN for %s:%s is %s", p.nameSpace, p.svcAcc, roleArn)

	return &roleArn, nil
}
