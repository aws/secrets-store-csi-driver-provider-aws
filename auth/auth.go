/*
 * Package responsible for returning an AWS SDK config with credentials
 * given an AWS region, K8s namespace, and K8s service account.
 */
package auth

import (
	"context"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/config"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/secrets-store-csi-driver-provider-aws/credential_provider"

	"k8s.io/klog/v2"
)

const (
	ProviderName = "secrets-store-csi-driver-provider-aws"
)

// ProviderVersion is injected at build time from the Makefile
var ProviderVersion = "unknown"

// Auth is the main entry point to retrieve an AWS config.
type Auth struct {
	region, nameSpace, svcAcc, preferredAddressType, eksAddonVersion string
	roleArn                                                          string
	usePodIdentity                                                   bool
	podIdentityHttpTimeout                                           *time.Duration
	serviceAccountTokens                                             string
	stsClient                                                        *sts.Client
}

// NewAuth creates an Auth object for an incoming mount request.
func NewAuth(
	region, nameSpace, svcAcc, preferredAddressType, eksAddonVersion string,
	roleArn string,
	usePodIdentity bool,
	podIdentityHttpTimeout *time.Duration,
	serviceAccountTokens string,
) (auth *Auth, e error) {
	var stsClient *sts.Client

	if !usePodIdentity {
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
		preferredAddressType:   preferredAddressType,
		eksAddonVersion:        eksAddonVersion,
		roleArn:                roleArn,
		usePodIdentity:         usePodIdentity,
		podIdentityHttpTimeout: podIdentityHttpTimeout,
		serviceAccountTokens:   serviceAccountTokens,
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

// GetAWSConfig returns the AWS config for the pod's service account.
func (p Auth) GetAWSConfig(ctx context.Context) (aws.Config, error) {
	var credProvider credential_provider.ConfigProvider
	var err error

	appID := p.getAppID()

	if p.usePodIdentity {
		klog.Infof("Using Pod Identity for authentication in namespace: %s, service account: %s", p.nameSpace, p.svcAcc)
		if p.podIdentityHttpTimeout != nil {
			klog.Infof("Using custom Pod Identity timeout: %v", *p.podIdentityHttpTimeout)
		}
		credProvider, err = credential_provider.NewPodIdentityCredentialProvider(
			p.region, p.preferredAddressType, p.podIdentityHttpTimeout, appID, p.serviceAccountTokens,
		)
	} else {
		klog.Infof("Using IAM Roles for Service Accounts for authentication in namespace: %s, service account: %s", p.nameSpace, p.svcAcc)
		credProvider, err = credential_provider.NewIRSACredentialProvider(
			p.stsClient, p.region, p.roleArn, appID, p.serviceAccountTokens,
		)
	}

	if err != nil {
		klog.Errorf("Error setting up credential provider")
		return aws.Config{}, err
	}

	return credProvider.GetAWSConfig(ctx)
}
