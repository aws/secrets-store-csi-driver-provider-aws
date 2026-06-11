package credential_provider

import (
	"context"
	"testing"
)

func TestNewIRSACredentialProvider(t *testing.T) {
	provider, err := NewIRSACredentialProvider(
		"someRegion",
		"arn:aws:iam::123456789012:role/test-role",
		"test-app-id",
		"irsa-test-token",
	)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if provider == nil {
		t.Fatal("Expected provider to be non-nil")
	}
}

func TestCSITokenFetcher(t *testing.T) {
	fetcher := &csiTokenFetcher{token: "test-token"}
	token, err := fetcher.GetIdentityToken()
	if err != nil {
		t.Errorf("Unexpected error: %v", err)
	}
	if string(token) != "test-token" {
		t.Errorf("Expected token %q, got %q", "test-token", string(token))
	}
}

func TestIRSACredentialProvider_GetAWSConfig(t *testing.T) {
	provider, err := NewIRSACredentialProvider(
		"someRegion",
		"arn:aws:iam::123456789012:role/test-role",
		"test-app-id",
		"irsa-test-token",
	)
	if err != nil {
		t.Fatalf("Failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if cfg.Credentials == nil {
		t.Error("Expected credentials to be non-nil")
	}
}
