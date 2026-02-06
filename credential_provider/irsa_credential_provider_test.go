package credential_provider

import (
	"context"
	"strings"
	"testing"
)

const validTokensJSON = `{
  "sts.amazonaws.com": {
    "token": "irsa-test-token",
    "expirationTimestamp": "2024-01-15T10:30:00Z"
  },
  "pods.eks.amazonaws.com": {
    "token": "pod-identity-test-token",
    "expirationTimestamp": "2024-01-15T10:30:00Z"
  }
}`

func TestNewIRSACredentialProvider(t *testing.T) {
	tests := []struct {
		name                 string
		roleArn              string
		serviceAccountTokens string
		wantErr              bool
		errContains          string
	}{
		{
			name:                 "success",
			roleArn:              "arn:aws:iam::123456789012:role/test-role",
			serviceAccountTokens: validTokensJSON,
			wantErr:              false,
		},
		{
			name:                 "empty role ARN",
			roleArn:              "",
			serviceAccountTokens: validTokensJSON,
			wantErr:              true,
			errContains:          "IAM role ARN is required",
		},
		{
			name:                 "empty tokens",
			roleArn:              "arn:aws:iam::123456789012:role/test-role",
			serviceAccountTokens: "",
			wantErr:              true,
			errContains:          "serviceAccount.tokens not provided",
		},
		{
			name:                 "missing sts audience",
			roleArn:              "arn:aws:iam::123456789012:role/test-role",
			serviceAccountTokens: `{"pods.eks.amazonaws.com": {"token": "test", "expirationTimestamp": "2024-01-15T10:30:00Z"}}`,
			wantErr:              true,
			errContains:          "sts.amazonaws.com",
		},
		{
			name:                 "invalid JSON",
			roleArn:              "arn:aws:iam::123456789012:role/test-role",
			serviceAccountTokens: "not json",
			wantErr:              true,
			errContains:          "failed to parse",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			provider, err := NewIRSACredentialProvider(
				&mockSTS{},
				testRegion,
				tt.roleArn,
				"test-app-id",
				tt.serviceAccountTokens,
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
		validTokensJSON,
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
