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

const validPodIdentityTokensJSON = `{
  "sts.amazonaws.com": {
    "token": "irsa-test-token",
    "expirationTimestamp": "2024-01-15T10:30:00Z"
  },
  "pods.eks.amazonaws.com": {
    "token": "pod-identity-test-token",
    "expirationTimestamp": "2024-01-15T10:30:00Z"
  }
}`

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
	tests := []struct {
		name                 string
		region               string
		serviceAccountTokens string
		wantErr              bool
		errContains          string
	}{
		{
			name:                 "success",
			region:               testRegion,
			serviceAccountTokens: validPodIdentityTokensJSON,
			wantErr:              false,
		},
		{
			name:                 "empty region",
			region:               "",
			serviceAccountTokens: validPodIdentityTokensJSON,
			wantErr:              true,
			errContains:          "region cannot be empty",
		},
		{
			name:                 "empty tokens",
			region:               testRegion,
			serviceAccountTokens: "",
			wantErr:              true,
			errContains:          "serviceAccount.tokens not provided",
		},
		{
			name:                 "missing pod identity audience",
			region:               testRegion,
			serviceAccountTokens: `{"sts.amazonaws.com": {"token": "test", "expirationTimestamp": "2024-01-15T10:30:00Z"}}`,
			wantErr:              true,
			errContains:          "pods.eks.amazonaws.com",
		},
		{
			name:                 "invalid JSON",
			region:               testRegion,
			serviceAccountTokens: "not json",
			wantErr:              true,
			errContains:          "failed to parse",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			provider, err := NewPodIdentityCredentialProvider(
				tt.region,
				"",
				nil,
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
		testRegion,
		"",
		&oneHundredMs,
		"test-app-id",
		validPodIdentityTokensJSON,
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
		testRegion,
		"ipv4",
		nil,
		"test-app-id",
		validPodIdentityTokensJSON,
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
		testRegion,
		"ipv6",
		nil,
		"test-app-id",
		validPodIdentityTokensJSON,
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
