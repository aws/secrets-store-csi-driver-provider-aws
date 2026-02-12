package auth

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/sts"
)

func TestNewAuth(t *testing.T) {
	tests := []struct {
		name           string
		region         string
		usePodIdentity bool
		expectError    bool
	}{
		{
			name:           "valid auth with IRSA",
			region:         "us-west-2",
			usePodIdentity: false,
			expectError:    false,
		},
		{
			name:           "valid auth with Pod Identity",
			region:         "us-east-1",
			usePodIdentity: true,
			expectError:    false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			timeout := 100 * time.Millisecond

			auth, err := NewAuth(
				tt.region,
				"default",
				"test-sa",
				"",
				"test-version",
				"arn:aws:iam::123456789012:role/test-role",
				tt.usePodIdentity,
				&timeout,
				"pre-extracted-test-token",
			)

			if tt.expectError && err == nil {
				t.Errorf("expected error but got none")
			}
			if !tt.expectError && err != nil {
				t.Errorf("unexpected error: %v", err)
			}

			if !tt.expectError && auth != nil {
				if auth.region != tt.region {
					t.Errorf("expected region %s, got %s", tt.region, auth.region)
				}
				if auth.usePodIdentity != tt.usePodIdentity {
					t.Errorf("expected usePodIdentity %v, got %v", tt.usePodIdentity, auth.usePodIdentity)
				}
				if auth.token != "pre-extracted-test-token" {
					t.Error("expected token to be set")
				}
			}
		})
	}
}

func TestGetAWSConfig(t *testing.T) {
	tests := []struct {
		name           string
		usePodIdentity bool
		token          string
		roleArn        string
		wantErr        bool
		errContains    string
	}{
		{
			name:           "IRSA success",
			usePodIdentity: false,
			token:          "irsa-test-token",
			roleArn:        "arn:aws:iam::123456789012:role/test-role",
			wantErr:        false,
		},
		{
			name:           "IRSA empty token",
			usePodIdentity: false,
			token:          "",
			roleArn:        "arn:aws:iam::123456789012:role/test-role",
			wantErr:        true,
			errContains:    "IRSA token cannot be empty",
		},
		{
			name:           "Pod Identity empty token",
			usePodIdentity: true,
			token:          "",
			roleArn:        "",
			wantErr:        true,
			errContains:    "Pod Identity token cannot be empty",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			timeout := 100 * time.Millisecond

			auth := &Auth{
				region:                 "us-west-2",
				nameSpace:              "default",
				svcAcc:                 "test-sa",
				roleArn:                tt.roleArn,
				usePodIdentity:         tt.usePodIdentity,
				podIdentityHttpTimeout: &timeout,
				token:                  tt.token,
			}

			if !tt.usePodIdentity {
				auth.stsClient = sts.New(sts.Options{Region: "us-west-2"})
			}

			cfg, err := auth.GetAWSConfig(context.Background())

			if tt.wantErr {
				if err == nil {
					t.Errorf("expected error but got none")
					return
				}
				if !strings.Contains(err.Error(), tt.errContains) {
					t.Errorf("expected error containing %q, got %q", tt.errContains, err.Error())
				}
				return
			}

			if err != nil {
				t.Errorf("unexpected error: %v", err)
				return
			}
			if cfg.Credentials == nil {
				t.Error("expected credentials to be non-nil")
			}
		})
	}
}

func TestAppID(t *testing.T) {
	tests := []struct {
		name            string
		eksAddonVersion string
		expectedAppID   string
	}{
		{
			name:            "with EKS addon version",
			eksAddonVersion: "v1.0.0-eksbuild.1",
			expectedAppID:   ProviderName + "-v1.0.0-eksbuild.1",
		},
		{
			name:            "without EKS addon version",
			eksAddonVersion: "",
			expectedAppID:   ProviderName + "-" + ProviderVersion,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			auth := &Auth{
				eksAddonVersion: tt.eksAddonVersion,
			}

			appID := auth.getAppID()
			if appID != tt.expectedAppID {
				t.Errorf("getAppID() = %q, want %q", appID, tt.expectedAppID)
			}
		})
	}
}
