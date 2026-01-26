package auth

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/smithy-go/middleware"
	smithyhttp "github.com/aws/smithy-go/transport/http"
	"k8s.io/client-go/kubernetes/fake"
)

// Mock STS client
type mockSTS struct {
	sts.Client
}

func (m *mockSTS) AssumeRoleWithWebIdentity(ctx context.Context, params *sts.AssumeRoleWithWebIdentityInput, optFns ...func(*sts.Options)) (*sts.AssumeRoleWithWebIdentityOutput, error) {
	return nil, fmt.Errorf("fake error for serviceaccount")
}

type sessionTest struct {
	testName        string
	testPodIdentity bool
	expError        string
}

var sessionTests []sessionTest = []sessionTest{
	{
		testName:        "IRSA",
		testPodIdentity: false,
		expError:        "serviceaccounts", // IRSA path will fail at getting service account since using fake client
	},
	{
		testName:        "Pod Identity",
		testPodIdentity: true,
		expError:        "", // Pod Identity path succeeds since token is lazy loaded
	},
}

func TestNewAuth(t *testing.T) {
	tests := []struct {
		name                   string
		region                 string
		nameSpace              string
		svcAcc                 string
		podName                string
		preferredAddressType   string
		usePodIdentity         bool
		podIdentityHttpTimeout time.Duration
		expectError            bool
	}{
		{
			name:                   "valid auth with pod identity",
			region:                 "us-west-2",
			nameSpace:              "default",
			svcAcc:                 "test-sa",
			podName:                "test-pod",
			preferredAddressType:   "ipv4",
			usePodIdentity:         true,
			podIdentityHttpTimeout: 100 * time.Millisecond,
			expectError:            false,
		},
		{
			name:                   "valid auth with IRSA",
			region:                 "us-east-1",
			nameSpace:              "kube-system",
			svcAcc:                 "irsa-sa",
			podName:                "irsa-pod",
			preferredAddressType:   "ipv6",
			usePodIdentity:         false,
			podIdentityHttpTimeout: 100 * time.Millisecond,
			expectError:            false,
		},
		{
			name:                   "valid auth with empty preferred address type",
			region:                 "eu-west-1",
			nameSpace:              "test-ns",
			svcAcc:                 "test-sa",
			podName:                "test-pod",
			preferredAddressType:   "",
			usePodIdentity:         true,
			podIdentityHttpTimeout: 50 * time.Millisecond,
			expectError:            false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			k8sClient := fake.NewSimpleClientset().CoreV1()

			auth, err := NewAuth(
				tt.region,
				tt.nameSpace,
				tt.svcAcc,
				tt.podName,
				tt.preferredAddressType,
				"test-version",
				tt.usePodIdentity,
				&tt.podIdentityHttpTimeout,
				k8sClient,
			)

			if tt.expectError && err == nil {
				t.Errorf("Expected error but got none")
			}
			if !tt.expectError && err != nil {
				t.Errorf("Unexpected error: %v", err)
			}

			if !tt.expectError && auth != nil {
				// Verify all fields are set correctly
				if auth.region != tt.region {
					t.Errorf("Expected region %s, got %s", tt.region, auth.region)
				}
				if auth.nameSpace != tt.nameSpace {
					t.Errorf("Expected namespace %s, got %s", tt.nameSpace, auth.nameSpace)
				}
				if auth.svcAcc != tt.svcAcc {
					t.Errorf("Expected service account %s, got %s", tt.svcAcc, auth.svcAcc)
				}
				if auth.podName != tt.podName {
					t.Errorf("Expected pod name %s, got %s", tt.podName, auth.podName)
				}
				if auth.preferredAddressType != tt.preferredAddressType {
					t.Errorf("Expected preferred address type %s, got %s", tt.preferredAddressType, auth.preferredAddressType)
				}
				if auth.usePodIdentity != tt.usePodIdentity {
					t.Errorf("Expected usePodIdentity %v, got %v", tt.usePodIdentity, auth.usePodIdentity)
				}
				if *auth.podIdentityHttpTimeout != tt.podIdentityHttpTimeout {
					t.Errorf("Expected podIdentityHttpTimeout %v, got %v", tt.podIdentityHttpTimeout, auth.podIdentityHttpTimeout)
				}
				if auth.k8sClient == nil {
					t.Error("Expected k8sClient to be set")
				}
				if auth.stsClient == nil {
					t.Error("Expected stsClient to be set")
				}
			}
		})
	}
}

func TestGetAWSConfig(t *testing.T) {
	for _, tstData := range sessionTests {
		t.Run(tstData.testName, func(t *testing.T) {

			timeout := 100 * time.Millisecond

			auth := &Auth{
				region:                 "someRegion",
				nameSpace:              "someNamespace",
				svcAcc:                 "someSvcAcc",
				podName:                "somepod",
				usePodIdentity:         tstData.testPodIdentity,
				podIdentityHttpTimeout: &timeout,
				k8sClient:              fake.NewSimpleClientset().CoreV1(),
				stsClient:              &mockSTS{},
			}

			cfg, err := auth.GetAWSConfig(context.Background())

			if len(tstData.expError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected auth error: %s", tstData.testName, err)
			}
			if len(tstData.expError) == 0 && cfg.Credentials == nil {
				t.Errorf("%s case: got empty session", tstData.testName)
			}
			if len(tstData.expError) != 0 && err == nil {
				t.Errorf("%s case: expected error but got none", tstData.testName)
			}
			if len(tstData.expError) != 0 && err != nil && !strings.Contains(err.Error(), tstData.expError) {
				t.Errorf("%s case: expected error prefix '%s' but got '%s'", tstData.testName, tstData.expError, err.Error())
			}
		})
	}
}

func TestGetAWSConfig_UserAgent(t *testing.T) {
	tests := []struct {
		name                   string
		eksAddonVersion        string
		expectAddonVersionInUA bool
	}{
		{
			name:                   "with EKS addon version",
			eksAddonVersion:        "v1.0.0-eksbuild.1",
			expectAddonVersionInUA: true,
		},
		{
			name:                   "without EKS addon version",
			eksAddonVersion:        "",
			expectAddonVersionInUA: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			timeout := 100 * time.Millisecond

			auth := &Auth{
				region:                 "us-west-2",
				nameSpace:              "default",
				svcAcc:                 "test-sa",
				podName:                "test-pod",
				eksAddonVersion:        tt.eksAddonVersion,
				usePodIdentity:         true,
				podIdentityHttpTimeout: &timeout,
				k8sClient:              fake.NewSimpleClientset().CoreV1(),
			}

			cfg, err := auth.GetAWSConfig(context.Background())
			if err != nil {
				t.Fatalf("GetAWSConfig() error = %v", err)
			}

			// Apply APIOptions to a stack and build a request to verify User-Agent header
			stack := middleware.NewStack("test", smithyhttp.NewStackRequest)
			for _, opt := range cfg.APIOptions {
				if err := opt(stack); err != nil {
					t.Fatalf("Failed to apply APIOption: %v", err)
				}
			}

			// Get the UserAgent middleware and execute HandleBuild to populate the header
			uaMiddleware, ok := stack.Build.Get("UserAgent")
			if !ok {
				t.Fatal("Expected UserAgent middleware in Build step")
			}

			req := smithyhttp.NewStackRequest()
			input := middleware.BuildInput{Request: req}
			_, _, err = uaMiddleware.HandleBuild(context.Background(), input, middleware.BuildHandlerFunc(
				func(ctx context.Context, in middleware.BuildInput) (middleware.BuildOutput, middleware.Metadata, error) {
					return middleware.BuildOutput{}, middleware.Metadata{}, nil
				},
			))
			if err != nil {
				t.Fatalf("HandleBuild() error = %v", err)
			}

			// Verify User-Agent header contains expected values
			httpReq := req.(*smithyhttp.Request)
			userAgent := httpReq.Header.Get("User-Agent")

			if !strings.Contains(userAgent, ProviderName+"/"+ProviderVersion) {
				t.Errorf("User-Agent should contain '%s/%s', got: %s", ProviderName, ProviderVersion, userAgent)
			}

			if tt.expectAddonVersionInUA {
				if !strings.Contains(userAgent, "eksAddonVersion/"+tt.eksAddonVersion) {
					t.Errorf("User-Agent should contain 'eksAddonVersion/%s', got: %s", tt.eksAddonVersion, userAgent)
				}
			} else {
				if strings.Contains(userAgent, "eksAddonVersion") {
					t.Errorf("User-Agent should not contain 'eksAddonVersion', got: %s", userAgent)
				}
			}
		})
	}
}
