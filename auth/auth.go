/*
 * Package responsible for returning an AWS SDK config with credentials
 * given an AWS region, K8s namespace, and K8s service account.
 *
 * This package requries that the K8s service account be associated with an IAM
 * role via IAM Roles for Service Accounts (IRSA).
 */
package auth

import (
	"context"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/secrets-store-csi-driver-provider-aws/credential_provider"

	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"k8s.io/klog/v2"
)

const (
	ProviderName = "secrets-store-csi-driver-provider-aws"
)

// ProviderVersion is injected at build time from the Makefile
var ProviderVersion = "unknown"

// Auth is the main entry point to retrieve an AWS config. The caller
// initializes a new Auth object with NewAuth passing the region, namespace, pod name,
// K8s service account and usePodIdentity flag  (and request context). The caller can then obtain AWS
// config by calling GetAWSConfig. podIdentityHttpTimeout is used to specify the HTTP timeout used for
// Pod Identity auth
type Auth struct {
	region, nameSpace, svcAcc, podName, preferredAddressType, eksAddonVersion string
	usePodIdentity                                                            bool
	podIdentityHttpTimeout                                                    *time.Duration
	k8sClient                                                                 k8sv1.CoreV1Interface
	stsClient                                                                 stscreds.AssumeRoleWithWebIdentityAPIClient
}

// NewAuth creates an Auth object for an incoming mount request.
func NewAuth(
	region, nameSpace, svcAcc, podName, preferredAddressType, eksAddonVersion string,
	usePodIdentity bool,
	podIdentityHttpTimeout *time.Duration,
	k8sClient k8sv1.CoreV1Interface,
) (auth *Auth, e error) {
	var stsClient *sts.Client

	if !usePodIdentity {
		// Get an initial config to use for STS calls when using IRSA
		cfg, err := config.LoadDefaultConfig(context.Background(),
			config.WithRegion(region),
			config.WithDefaultsMode(aws.DefaultsModeStandard),
		)
		if err != nil {
			return nil, err
		}
		stsClient = sts.NewFromConfig(cfg)
	}

	return &Auth{
		region:                 region,
		nameSpace:              nameSpace,
		svcAcc:                 svcAcc,
		podName:                podName,
		preferredAddressType:   preferredAddressType,
		eksAddonVersion:        eksAddonVersion,
		usePodIdentity:         usePodIdentity,
		podIdentityHttpTimeout: podIdentityHttpTimeout,
		k8sClient:              k8sClient,
		stsClient:              stsClient,
	}, nil

}

// getAppID returns the AppID string for User-Agent
func (p Auth) getAppID() string {
	version := ProviderVersion
	if p.eksAddonVersion != "" {
		version = p.eksAddonVersion
	}
	return ProviderName + "-" + version
}

// Get the AWS config associated with a given pod's service account.
// The returned config is capable of automatically refreshing creds as needed
// by using a private TokenFetcher helper.
func (p Auth) GetAWSConfig(ctx context.Context) (aws.Config, error) {
	var credProvider credential_provider.ConfigProvider

	appID := p.getAppID()

	if p.usePodIdentity {
		klog.Infof("Using Pod Identity for authentication in namespace: %s, service account: %s", p.nameSpace, p.svcAcc)
		if p.podIdentityHttpTimeout != nil {
			klog.Infof("Using custom Pod Identity timeout: %v", *p.podIdentityHttpTimeout)
		}
		var err error
		credProvider, err = credential_provider.NewPodIdentityCredentialProvider(p.region, p.nameSpace, p.svcAcc, p.podName, p.preferredAddressType, p.podIdentityHttpTimeout, appID, p.k8sClient)
		if err != nil {
			return aws.Config{}, err
		}
	} else {
		klog.Infof("Using IAM Roles for Service Accounts for authentication in namespace: %s, service account: %s", p.nameSpace, p.svcAcc)
		credProvider = credential_provider.NewIRSACredentialProvider(p.stsClient, p.region, p.nameSpace, p.svcAcc, appID, p.k8sClient)
	}

	return credProvider.GetAWSConfig(ctx)
}
