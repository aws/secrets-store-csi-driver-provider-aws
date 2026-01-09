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
		name                      string
		region                    string
		nameSpace                 string
		svcAcc                    string
		podName                   string
		preferredAddressType      string
		usePodIdentity            bool
		podIdentityHttpTimeout    time.Duration
		assumeRoleDurationSeconds time.Duration
		expectError               bool
	}{
		{
			name:                      "valid auth with pod identity",
			region:                    "us-west-2",
			nameSpace:                 "default",
			svcAcc:                    "test-sa",
			podName:                   "test-pod",
			preferredAddressType:      "ipv4",
			usePodIdentity:            true,
			podIdentityHttpTimeout:    100 * time.Millisecond,
			assumeRoleDurationSeconds: 0,
			expectError:               false,
		},
		{
			name:                      "valid auth with IRSA",
			region:                    "us-east-1",
			nameSpace:                 "kube-system",
			svcAcc:                    "irsa-sa",
			podName:                   "irsa-pod",
			preferredAddressType:      "ipv6",
			usePodIdentity:            false,
			podIdentityHttpTimeout:    100 * time.Millisecond,
			assumeRoleDurationSeconds: 0,
			expectError:               false,
		},
		{
			name:                      "valid auth with empty preferred address type",
			region:                    "eu-west-1",
			nameSpace:                 "test-ns",
			svcAcc:                    "test-sa",
			podName:                   "test-pod",
			preferredAddressType:      "",
			usePodIdentity:            true,
			podIdentityHttpTimeout:    50 * time.Millisecond,
			assumeRoleDurationSeconds: 0,
			expectError:               false,
		},
		{
			name:                      "valid auth with assume role duration",
			region:                    "us-west-2",
			nameSpace:                 "default",
			svcAcc:                    "test-sa",
			podName:                   "test-pod",
			preferredAddressType:      "ipv4",
			usePodIdentity:            true,
			podIdentityHttpTimeout:    100 * time.Millisecond,
			assumeRoleDurationSeconds: 3600 * time.Second,
			expectError:               false,
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
				"",
				tt.assumeRoleDurationSeconds,
				"",
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
				if auth.assumeRoleDurationSeconds != tt.assumeRoleDurationSeconds {
					t.Errorf("Expected assumeRoleDurationSeconds %v, got %v", tt.assumeRoleDurationSeconds, auth.assumeRoleDurationSeconds)
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

func TestGetAWSConfig_AssumeRole(t *testing.T) {
	timeout := 100 * time.Millisecond

	auth := &Auth{
		region:                    "someRegion",
		nameSpace:                 "someNamespace",
		svcAcc:                    "someSvcAcc",
		podName:                   "somepod",
		usePodIdentity:            true,
		podIdentityHttpTimeout:    &timeout,
		k8sClient:                 fake.NewSimpleClientset().CoreV1(),
		stsClient:                 &mockSTS{},
		assumeRoleArn:             "arn:aws:iam::123456789012:role/TestRole",
		assumeRoleDurationSeconds: 900 * time.Second,
	}

	cfg, err := auth.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("Unexpected error from GetAWSConfig with assume role: %v", err)
	}
	if cfg.Credentials == nil {
		t.Fatalf("Expected credentials to be set when assume role is configured")
	}
}

func TestUserAgentMiddleware_ID(t *testing.T) {
	middleware := &userAgentMiddleware{
		providerName:    "test-provider",
		eksAddonVersion: "test-version",
	}

	expectedID := "AppendCSIDriverVersionToUserAgent"
	actualID := middleware.ID()

	if actualID != expectedID {
		t.Errorf("Expected ID() to return '%s', but got '%s'", expectedID, actualID)
	}
}

func TestUserAgentMiddleware_HandleBuild(t *testing.T) {
	tests := []struct {
		name            string
		providerName    string
		eksAddonVersion string
		expectedUA      string
	}{
		{
			name:            "with EKS addon version",
			providerName:    "test-provider",
			eksAddonVersion: "v1.0.0-eksbuild.1",
			expectedUA:      "test-provider/unknown eksAddonVersion/v1.0.0-eksbuild.1",
		},
		{
			name:            "without EKS addon version",
			providerName:    "test-provider",
			eksAddonVersion: "",
			expectedUA:      "test-provider/unknown",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := &userAgentMiddleware{
				providerName:    tt.providerName,
				eksAddonVersion: tt.eksAddonVersion,
			}

			req := smithyhttp.NewStackRequest()

			input := middleware.BuildInput{Request: req}

			nextCalled := false
			next := middleware.BuildHandlerFunc(func(ctx context.Context, in middleware.BuildInput) (middleware.BuildOutput, middleware.Metadata, error) {
				nextCalled = true
				return middleware.BuildOutput{}, middleware.Metadata{}, nil
			})

			_, _, err := m.HandleBuild(context.Background(), input, next)

			if err != nil {
				t.Errorf("HandleBuild() error = %v", err)
			}

			if !nextCalled {
				t.Error("Expected next handler to be called")
			}

			// Cast to smithyhttp.Request to access Header
			if smithyReq, ok := input.Request.(*smithyhttp.Request); ok {
				userAgents := smithyReq.Header["User-Agent"]
				if len(userAgents) == 0 {
					t.Error("Expected User-Agent header to be set")
				} else if userAgents[0] != tt.expectedUA {
					t.Errorf("Expected User-Agent '%s', got '%s'", tt.expectedUA, userAgents[0])
				}
			} else {
				t.Error("Expected request to be *smithyhttp.Request")
			}
		})
	}
}

// TestGetAWSConfig_AssumeRoleDurations tests various duration scenarios
func TestGetAWSConfig_AssumeRoleDurations(t *testing.T) {
	tests := []struct {
		name        string
		duration    time.Duration
		expectError bool
	}{
		{
			name:        "valid duration - 15 minutes",
			duration:    15 * time.Minute,
			expectError: false,
		},
		{
			name:        "valid duration - 1 hour",
			duration:    1 * time.Hour,
			expectError: false,
		},
		{
			name:        "valid duration - 12 hours",
			duration:    12 * time.Hour,
			expectError: false,
		},
		{
			name:        "zero duration",
			duration:    0,
			expectError: false,
		},
		{
			name:        "minimum valid duration - 1 second",
			duration:    1 * time.Second,
			expectError: false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			timeout := 100 * time.Millisecond

			auth := &Auth{
				region:                    "someRegion",
				nameSpace:                 "someNamespace",
				svcAcc:                    "someSvcAcc",
				podName:                   "somepod",
				usePodIdentity:            true,
				podIdentityHttpTimeout:    &timeout,
				k8sClient:                 fake.NewSimpleClientset().CoreV1(),
				stsClient:                 &mockSTS{},
				assumeRoleArn:             "arn:aws:iam::123456789012:role/TestRole",
				assumeRoleDurationSeconds: tt.duration,
			}

			cfg, err := auth.GetAWSConfig(context.Background())
			if tt.expectError && err == nil {
				t.Fatalf("Expected error but got none")
			}
			if !tt.expectError && err != nil {
				t.Fatalf("Unexpected error: %v", err)
			}
			if !tt.expectError && cfg.Credentials == nil {
				t.Fatalf("Expected credentials to be set")
			}
		})
	}
}

// TestGetAWSConfig_AssumeRoleWithExternalId tests assume role with external ID
func TestGetAWSConfig_AssumeRoleWithExternalId(t *testing.T) {
	timeout := 100 * time.Millisecond

	auth := &Auth{
		region:                    "someRegion",
		nameSpace:                 "someNamespace",
		svcAcc:                    "someSvcAcc",
		podName:                   "somepod",
		usePodIdentity:            true,
		podIdentityHttpTimeout:    &timeout,
		k8sClient:                 fake.NewSimpleClientset().CoreV1(),
		stsClient:                 &mockSTS{},
		assumeRoleArn:             "arn:aws:iam::123456789012:role/TestRole",
		assumeRoleDurationSeconds: 3600 * time.Second,
		assumeRoleExternalId:      "external-id-123",
	}

	cfg, err := auth.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if cfg.Credentials == nil {
		t.Fatalf("Expected credentials to be set")
	}
}

// TestGetAWSConfig_AssumeRoleWithoutDuration tests assume role without duration (should use AWS default)
func TestGetAWSConfig_AssumeRoleWithoutDuration(t *testing.T) {
	timeout := 100 * time.Millisecond

	auth := &Auth{
		region:                    "someRegion",
		nameSpace:                 "someNamespace",
		svcAcc:                    "someSvcAcc",
		podName:                   "somepod",
		usePodIdentity:            true,
		podIdentityHttpTimeout:    &timeout,
		k8sClient:                 fake.NewSimpleClientset().CoreV1(),
		stsClient:                 &mockSTS{},
		assumeRoleArn:             "arn:aws:iam::123456789012:role/TestRole",
		assumeRoleDurationSeconds: 0,
	}

	cfg, err := auth.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if cfg.Credentials == nil {
		t.Fatalf("Expected credentials to be set")
	}
}

// TestGetAWSConfig_NoAssumeRole tests when no assume role is configured
func TestGetAWSConfig_NoAssumeRole(t *testing.T) {
	timeout := 100 * time.Millisecond

	auth := &Auth{
		region:                 "someRegion",
		nameSpace:              "someNamespace",
		svcAcc:                 "someSvcAcc",
		podName:                "somepod",
		usePodIdentity:         true,
		podIdentityHttpTimeout: &timeout,
		k8sClient:              fake.NewSimpleClientset().CoreV1(),
		stsClient:              &mockSTS{},
		assumeRoleArn:          "",
	}

	cfg, err := auth.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if cfg.Credentials == nil {
		t.Fatalf("Expected credentials to be set")
	}
}
