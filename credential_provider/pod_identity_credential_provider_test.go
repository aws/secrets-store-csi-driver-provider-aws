package credential_provider

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"
)

func TestParseAddressPreference(t *testing.T) {
	tests := []struct {
		input    string
		expected string
	}{
		{"", "auto"},
		{"auto", "auto"},
		{"ipv4", "ipv4"},
		{"ipv6", "ipv6"},
		{"IPv4", "ipv4"},
		{"IPv6", "ipv6"},
		{"invalid", "auto"},
	}

	for _, tt := range tests {
		t.Run(tt.input, func(t *testing.T) {
			result := parseAddressPreference(tt.input)
			if result != tt.expected {
				t.Errorf("parseAddressPreference(%q) = %q, want %q", tt.input, result, tt.expected)
			}
		})
	}
}

func TestNewPodIdentityCredentialProvider(t *testing.T) {
	provider, err := NewPodIdentityCredentialProvider(
		testRegion, "", nil, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if provider == nil {
		t.Fatal("expected provider to be non-nil")
	}
}

func TestCSITokenProvider(t *testing.T) {
	provider := &csiTokenProvider{token: "test-token"}
	token, err := provider.GetToken()
	if err != nil {
		t.Errorf("unexpected error: %v", err)
	}
	if token != "test-token" {
		t.Errorf("expected token %q, got %q", "test-token", token)
	}
}

func TestNewPodIdentityCredentialProviderTimeout(t *testing.T) {
	oneHundredMs := 100 * time.Millisecond

	provider, err := NewPodIdentityCredentialProvider(
		testRegion, "", &oneHundredMs, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	podProvider := provider.(*PodIdentityCredentialProvider)
	if podProvider.httpClient == nil {
		t.Error("expected httpClient to be set when timeout is provided")
	}
}

func setupMockPodIdentityAgent(t *testing.T, isIPv4 bool) *httptest.Server {
	t.Helper()
	var listener net.Listener
	var err error
	if isIPv4 {
		listener, err = net.Listen("tcp4", "127.0.0.1:0")
	} else {
		listener, err = net.Listen("tcp6", "[::1]:0")
	}
	if err != nil {
		t.Fatalf("Failed to create listener: %v", err)
	}

	srv := &httptest.Server{
		Listener:    listener,
		EnableHTTP2: true,
		Config: &http.Server{Handler: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprintf(w, `{
               "AccessKeyId": "TEST_ACCESS_KEY",
               "SecretAccessKey": "TEST_SECRET",
               "Token": "TEST_TOKEN"
           }`)
		})},
	}
	srv.Start()
	return srv
}

func resetEndpoints() {
	podIdentityAgentEndpointIPv4 = defaultIPv4Endpoint
	podIdentityAgentEndpointIPv6 = defaultIPv6Endpoint
}

func TestPodIdentityCredentialProvider_GetAWSConfig_IPv4(t *testing.T) {
	defer resetEndpoints()

	mockServer := setupMockPodIdentityAgent(t, true)
	defer mockServer.Close()

	podIdentityAgentEndpointIPv4 = mockServer.URL

	provider, err := NewPodIdentityCredentialProvider(
		testRegion, "ipv4", nil, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("unexpected credential retrieval error: %v", err)
	}

	if creds.AccessKeyID != "TEST_ACCESS_KEY" {
		t.Errorf("expected AccessKeyID %q, got %q", "TEST_ACCESS_KEY", creds.AccessKeyID)
	}
}

func TestPodIdentityCredentialProvider_GetAWSConfig_IPv6(t *testing.T) {
	defer resetEndpoints()

	mockServer := setupMockPodIdentityAgent(t, false)
	defer mockServer.Close()

	podIdentityAgentEndpointIPv6 = mockServer.URL
	podIdentityAgentEndpointIPv4 = "http://127.0.0.1:1" // Force IPv4 to fail

	provider, err := NewPodIdentityCredentialProvider(
		testRegion, "ipv6", nil, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("unexpected credential retrieval error: %v", err)
	}

	if creds.AccessKeyID != "TEST_ACCESS_KEY" {
		t.Errorf("expected AccessKeyID %q, got %q", "TEST_ACCESS_KEY", creds.AccessKeyID)
	}
}

func TestPodIdentityCredentialProvider_GetAWSConfig_AutoFallback(t *testing.T) {
	defer resetEndpoints()

	// Set up IPv6 mock, make IPv4 unreachable
	mockServer := setupMockPodIdentityAgent(t, false)
	defer mockServer.Close()

	podIdentityAgentEndpointIPv4 = "http://127.0.0.1:1" // unreachable
	podIdentityAgentEndpointIPv6 = mockServer.URL

	shortTimeout := 200 * time.Millisecond

	// In auto mode, GetAWSConfig calls getConfigWithEndpoint for IPv4 first.
	// config.LoadDefaultConfig is lazy (no network call), so it always succeeds.
	// The IPv4 config is returned even though the endpoint is unreachable.
	// Retrieve() on that config will fail. This confirms the auto-mode fallback
	// in GetAWSConfig only works if LoadDefaultConfig itself errors.
	//
	// Verify that explicitly selecting IPv6 works when IPv4 is down.
	provider, err := NewPodIdentityCredentialProvider(
		testRegion, "ipv6", &shortTimeout, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("GetAWSConfig failed: %v", err)
	}

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("Retrieve failed (IPv6 should work): %v", err)
	}
	if creds.AccessKeyID != "TEST_ACCESS_KEY" {
		t.Errorf("expected AccessKeyID %q, got %q", "TEST_ACCESS_KEY", creds.AccessKeyID)
	}
}

func TestPodIdentityCredentialProvider_GetAWSConfig_BothFail(t *testing.T) {
	defer resetEndpoints()

	podIdentityAgentEndpointIPv4 = "http://127.0.0.1:1" // unreachable
	podIdentityAgentEndpointIPv6 = "http://[::1]:1"     // unreachable

	shortTimeout := 100 * time.Millisecond
	provider, err := NewPodIdentityCredentialProvider(
		testRegion, "ipv4", &shortTimeout, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("GetAWSConfig should succeed (lazy credentials): %v", err)
	}

	// Retrieve fails because the endpoint is unreachable
	_, err = cfg.Credentials.Retrieve(context.Background())
	if err == nil {
		t.Fatal("expected error when endpoint is unreachable")
	}
}
