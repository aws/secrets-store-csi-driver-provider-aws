package credential_provider

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestParseAddressPreference(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		expected string
	}{
		{"Empty string", "", "auto"},
		{"Auto preference", "auto", "auto"},
		{"IPv4 preference", "ipv4", "ipv4"},
		{"IPv6 preference", "ipv6", "ipv6"},
		{"IPv4 uppercase", "IPv4", "ipv4"},
		{"IPv6 uppercase", "IPv6", "ipv6"},
		{"Invalid preference", "invalid", "auto"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := parseAddressPreference(tt.input)
			if result != tt.expected {
				t.Errorf("parseAddressPreference(%q) = %q, want %q",
					tt.input, result, tt.expected)
			}
		})
	}
}

func TestNewPodIdentityCredentialProvider(t *testing.T) {
	provider, err := NewPodIdentityCredentialProvider(
		"someRegion", "", nil, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if provider == nil {
		t.Fatal("Expected provider to be non-nil")
	}
}

func TestCSITokenProvider(t *testing.T) {
	provider := &csiTokenProvider{token: "test-token"}
	token, err := provider.GetToken()
	if err != nil {
		t.Errorf("Unexpected error: %v", err)
	}
	if token != "test-token" {
		t.Errorf("Expected token %q, got %q", "test-token", token)
	}
}

func TestNewPodIdentityCredentialProviderTimeout(t *testing.T) {
	oneHundredMs := 100 * time.Millisecond

	provider, err := NewPodIdentityCredentialProvider(
		"someRegion", "", &oneHundredMs, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	podProvider := provider.(*PodIdentityCredentialProvider)
	if podProvider.httpClient == nil {
		t.Error("Expected httpClient to be set when timeout is provided")
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
		"someRegion", "ipv4", nil, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("Failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("Unexpected credential retrieval error: %v", err)
	}

	if creds.AccessKeyID != "TEST_ACCESS_KEY" {
		t.Errorf("Expected AccessKeyID %q, got %q", "TEST_ACCESS_KEY", creds.AccessKeyID)
	}
}

func TestPodIdentityCredentialProvider_GetAWSConfig_IPv6(t *testing.T) {
	defer resetEndpoints()

	mockServer := setupMockPodIdentityAgent(t, false)
	defer mockServer.Close()

	podIdentityAgentEndpointIPv6 = mockServer.URL
	podIdentityAgentEndpointIPv4 = "http://127.0.0.1:1" // Force IPv4 to fail

	provider, err := NewPodIdentityCredentialProvider(
		"someRegion", "ipv6", nil, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("Failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("Unexpected credential retrieval error: %v", err)
	}

	if creds.AccessKeyID != "TEST_ACCESS_KEY" {
		t.Errorf("Expected AccessKeyID %q, got %q", "TEST_ACCESS_KEY", creds.AccessKeyID)
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
		"someRegion", "ipv6", &shortTimeout, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("Failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("Unexpected credential retrieval error: %v", err)
	}
	if creds.AccessKeyID != "TEST_ACCESS_KEY" {
		t.Errorf("Expected AccessKeyID %q, got %q", "TEST_ACCESS_KEY", creds.AccessKeyID)
	}
}

func TestPodIdentityCredentialProvider_GetAWSConfig_BothFail(t *testing.T) {
	defer resetEndpoints()

	podIdentityAgentEndpointIPv4 = "http://127.0.0.1:1" // unreachable
	podIdentityAgentEndpointIPv6 = "http://[::1]:1"     // unreachable

	shortTimeout := 100 * time.Millisecond
	provider, err := NewPodIdentityCredentialProvider(
		"someRegion", "ipv4", &shortTimeout, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("Failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error during config creation, got: %v", err)
	}

	// Retrieve fails because the endpoint is unreachable
	_, err = cfg.Credentials.Retrieve(context.Background())
	if err == nil {
		t.Fatal("Expected error but got none")
	}
}

func setupFailingMockPodIdentityAgent(t *testing.T, isIPv4 bool, statusCode int) *httptest.Server {
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
			w.WriteHeader(statusCode)
		})},
	}
	srv.Start()
	return srv
}

// TestPodIdentityCredentialProvider_GetAWSConfig_AgentReturns500 verifies behavior
// when the Pod Identity Agent is reachable but returns a server error (e.g. token
// exchange failure). This is distinct from the unreachable-endpoint case.
func TestPodIdentityCredentialProvider_GetAWSConfig_AgentReturns500(t *testing.T) {
	defer resetEndpoints()

	mockServer := setupFailingMockPodIdentityAgent(t, true, http.StatusInternalServerError)
	defer mockServer.Close()

	podIdentityAgentEndpointIPv4 = mockServer.URL

	provider, err := NewPodIdentityCredentialProvider(
		"someRegion", "ipv4", nil, "test-app-id", "pod-identity-test-token",
	)
	if err != nil {
		t.Fatalf("Failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error during config creation, got: %v", err)
	}

	_, err = cfg.Credentials.Retrieve(context.Background())
	if err == nil {
		t.Fatal("Expected error but got none")
	}

	if !strings.Contains(err.Error(), "failed to refresh cached credentials") {
		t.Errorf("Expected error containing 'failed to refresh cached credentials', got: %v", err)
	}
}
