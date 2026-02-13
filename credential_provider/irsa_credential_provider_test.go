package credential_provider

import (
	"context"
	"testing"
)

func TestNewIRSACredentialProvider(t *testing.T) {
	provider, err := NewIRSACredentialProvider(
		testRegion,
		"arn:aws:iam::123456789012:role/test-role",
		"test-app-id",
		"irsa-test-token",
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if provider == nil {
		t.Fatal("expected provider to be non-nil")
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
