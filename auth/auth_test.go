package auth

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/service/sts"
	"k8s.io/client-go/kubernetes/fake"
)

// Mock STS client
type mockSTS struct {
	sts.Client
}

func (m *mockSTS) AssumeRoleWithWebIdentity(ctx context.Context, params *sts.AssumeRoleWithWebIdentityInput, optFns ...func(*sts.Options)) (*sts.AssumeRoleWithWebIdentityOutput, error) {
	return nil, fmt.Errorf("fake error for serviceaccounst")
}

type sessionTest struct {
	testName        string
	testPodIdentity bool
	cfgError        string
}

func TestGetAWSSession(t *testing.T) {
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

			auth, err := NewAuth(
				"someRegion",
				"someNamespace",
				"someSvcAcc",
				"somepod",
				"",
				tt.testPodIdentity,
				fake.NewSimpleClientset().CoreV1(),
			)
			if err != nil {
				t.Fatalf("%s case: failed to create auth: %v", tt.testName, err)
			}
			auth.stsClient = &mockSTS{}
			auth.k8sClient = fake.NewSimpleClientset().CoreV1()

			cfg, err := auth.GetAWSConfig(context.Background())

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
