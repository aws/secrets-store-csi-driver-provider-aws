package auth

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/secrets-store-csi-driver-provider-aws/credential_provider"
	"k8s.io/client-go/kubernetes/fake"
)

// Mock STS client
type mockSTS struct {
	sts.Client
}

func (m *mockSTS) AssumeRoleWithWebIdentity(context.Context, *sts.AssumeRoleWithWebIdentityInput, ...func(*sts.Options)) (*sts.AssumeRoleWithWebIdentityOutput, error) {
	return nil, fmt.Errorf("fake error for serviceaccounts")
}

type sessionTest struct {
	testName        string
	testPodIdentity bool
	cfgError        string
}

func TestGetAWSConfig(t *testing.T) {
	const (
		region         = "someRegion"
		namespace      = "someNamespace"
		serviceAccount = "someSvcAcc"
	)

	cases := []sessionTest{
		{
			testName:        "IRSA",
			testPodIdentity: false,
			cfgError:        "serviceaccounts", // IRSA path will fail at getting creds since its in the hot path of the config
		},
		{
			testName:        "Pod Identity",
			testPodIdentity: true,
			cfgError:        "", // Pod Identity path succeeds since token is lazy loaded
		},
	}
	for _, tt := range cases {
		t.Run(tt.testName, func(t *testing.T) {
			var (
				provider credential_provider.ConfigProvider
				err      error
			)

			tokenFetcher := credential_provider.NewTokenFetcher(nil, "someVolumeID", region)
			k8sClient := fake.NewClientset().CoreV1()

			if tt.testPodIdentity {
				provider, err = NewPodIdentityAuth(region, "ipv4", tokenFetcher)
			} else {
				provider, err = NewIRSAAuth(region, namespace, serviceAccount, k8sClient, tokenFetcher)
				if err == nil {
					if irsaProvider, ok := provider.(*irsaAuth); ok {
						irsaProvider.stsClient = &mockSTS{}
					}
				}
			}

			if err != nil {
				t.Fatalf("%s case: failed to create auth: %v", tt.testName, err)
			}

			cfg, err := provider.GetAWSConfig(context.Background())

			if len(tt.cfgError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected auth error: %s", tt.testName, err)
			}
			if len(tt.cfgError) == 0 && cfg.Credentials == nil {
				t.Errorf("%s case: got empty credentials", tt.testName)
			}
			if len(tt.cfgError) != 0 && err == nil {
				t.Errorf("%s case: expected error but got none", tt.testName)
			}
			if len(tt.cfgError) != 0 && err != nil {
				if !strings.Contains(err.Error(), tt.cfgError) {
					t.Errorf("%s case: expected error prefix '%s' but got '%s'", tt.testName, tt.cfgError, err.Error())
				}
			}
		})
	}
}
