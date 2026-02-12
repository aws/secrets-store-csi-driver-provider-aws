package credential_provider

import (
	"context"
	"strings"
	"testing"
)

func TestNewIRSACredentialProvider(t *testing.T) {
	tests := []struct {
		name        string
		region      string
		roleArn     string
		token       string
		wantErr     bool
		errContains string
	}{
		{
			name:    "success",
			region:  testRegion,
			roleArn: "arn:aws:iam::123456789012:role/test-role",
			token:   "irsa-test-token",
			wantErr: false,
		},
		{
			name:        "empty region",
			region:      "",
			roleArn:     "arn:aws:iam::123456789012:role/test-role",
			token:       "irsa-test-token",
			wantErr:     true,
			errContains: "region cannot be empty",
		},
		{
			name:        "empty role ARN",
			region:      testRegion,
			roleArn:     "",
			token:       "irsa-test-token",
			wantErr:     true,
			errContains: "IAM role ARN is required",
		},
		{
			name:        "empty token",
			region:      testRegion,
			roleArn:     "arn:aws:iam::123456789012:role/test-role",
			token:       "",
			wantErr:     true,
			errContains: "IRSA token cannot be empty",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			provider, err := NewIRSACredentialProvider(
				&mockSTS{},
				tt.region,
				tt.roleArn,
				"test-app-id",
				tt.token,
			)

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
			if provider == nil {
				t.Error("expected provider to be non-nil")
			}
		})
	}
}

func TestCSITokenFetcher(t *testing.T) {
	fetcher := &csiTokenFetcher{token: "test-token"}
	token, err := fetcher.GetIdentityToken()
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if string(token) != "test-token" {
		t.Errorf("expected token %q, got %q", "test-token", string(token))
	}
}

func TestIRSACredentialProvider_GetAWSConfig(t *testing.T) {
	provider, err := NewIRSACredentialProvider(
		&mockSTS{},
		testRegion,
		"arn:aws:iam::123456789012:role/test-role",
		"test-app-id",
		"irsa-test-token",
	)
	if err != nil {
		t.Fatalf("failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Credentials == nil {
		t.Error("expected credentials to be non-nil")
	}
}
