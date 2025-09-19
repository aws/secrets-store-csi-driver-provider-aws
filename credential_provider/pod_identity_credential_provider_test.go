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

	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"k8s.io/client-go/kubernetes/fake"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
)

const (
	testPodName = "somePodName"
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

func setupMockPodIdentityAgent(t *testing.T, isIPv4, shouldFail bool) *httptest.Server {
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
			if shouldFail {
				w.WriteHeader(http.StatusInternalServerError)
				return
			}

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

func newPodIdentityCredentialWithMock(t *testing.T, isIPv4 bool, tstData podIdentityCredentialTest) (*PodIdentityCredentialProvider, chan<- struct{}) {
	k8sClient := &mockK8sV1{
		CoreV1Interface:  fake.NewSimpleClientset().CoreV1(),
		fake:             fake.NewSimpleClientset().CoreV1(),
		k8CTOneShotError: tstData.k8CTOneShotError,
	}

	mockServer := setupMockPodIdentityAgent(t, isIPv4, tstData.podIdentityError)
	respChan := make(chan struct{})
	go func(srv *httptest.Server) {
		<-respChan
		srv.Close()
	}(mockServer)

	if tstData.podIdentityError {
		if isIPv4 {
			podIdentityAgentEndpointIPv4 = "http://127.0.0.1:1"
		} else {
			podIdentityAgentEndpointIPv6 = "http://[::1]:1"
		}
	} else {
		if isIPv4 {
			podIdentityAgentEndpointIPv4 = mockServer.URL
			podIdentityAgentEndpointIPv6 = "http://[::1]:1"
		} else {
			podIdentityAgentEndpointIPv4 = "http://127.0.0.1:1"
			podIdentityAgentEndpointIPv6 = mockServer.URL
		}
	}

	return &PodIdentityCredentialProvider{
		region:               testRegion,
		preferredAddressType: tstData.preferredEndpoint,
		fetcher:              newPodIdentityTokenFetcher(testNamespace, testServiceAccount, testPodName, k8sClient),
		httpClient:           awshttp.NewBuildableClient(),
	}, respChan
}

type podIdentityCredentialTest struct {
	testName          string
	k8CTOneShotError  bool
	testToken         bool
	podIdentityError  bool
	preferredEndpoint string
	expError          string
}

func resetEndpoints() {
	podIdentityAgentEndpointIPv4 = defaultIPv4Endpoint
	podIdentityAgentEndpointIPv6 = defaultIPv6Endpoint
}

func TestPodIdentityCredentialProvider_IPv4Success(t *testing.T) {
	defer resetEndpoints()

	testData := podIdentityCredentialTest{
		testName:          "IPv4 Success",
		k8CTOneShotError:  false,
		podIdentityError:  false,
		preferredEndpoint: "ipv4",
		expError:          "",
	}

	provider, closer := newPodIdentityCredentialWithMock(t, true, testData)
	defer func() { closer <- struct{}{} }()

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("Unexpected credential retrieval error: %v", err)
	}

	if creds.AccessKeyID != "TEST_ACCESS_KEY" ||
		creds.SecretAccessKey != "TEST_SECRET" ||
		creds.SessionToken != "TEST_TOKEN" {
		t.Errorf("Unexpected credentials values")
	}
}

func TestPodIdentityCredentialProvider_IPv6Success(t *testing.T) {
	defer resetEndpoints()

	testData := podIdentityCredentialTest{
		testName:          "IPv6 Success",
		k8CTOneShotError:  false,
		podIdentityError:  false,
		preferredEndpoint: "ipv6",
		expError:          "",
	}

	provider, closer := newPodIdentityCredentialWithMock(t, false, testData)
	defer func() { closer <- struct{}{} }()

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("Unexpected credential retrieval error: %v", err)
	}

	if creds.AccessKeyID != "TEST_ACCESS_KEY" ||
		creds.SecretAccessKey != "TEST_SECRET" ||
		creds.SessionToken != "TEST_TOKEN" {
		t.Errorf("Unexpected credentials values")
	}
}

func TestPodIdentityCredentialProvider_AutoSelectionSuccess(t *testing.T) {
	defer resetEndpoints()

	testData := podIdentityCredentialTest{
		testName:          "Auto Selection Success",
		k8CTOneShotError:  false,
		podIdentityError:  false,
		preferredEndpoint: "auto",
		expError:          "",
	}

	provider, closer := newPodIdentityCredentialWithMock(t, true, testData)
	defer func() { closer <- struct{}{} }()

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error, got: %v", err)
	}

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("Unexpected credential retrieval error: %v", err)
	}

	if creds.AccessKeyID != "TEST_ACCESS_KEY" ||
		creds.SecretAccessKey != "TEST_SECRET" ||
		creds.SessionToken != "TEST_TOKEN" {
		t.Errorf("Unexpected credentials values")
	}
}

func TestPodIdentityCredentialProvider_IPv4Failure(t *testing.T) {
	defer resetEndpoints()

	testData := podIdentityCredentialTest{
		testName:          "IPv4 Failure",
		k8CTOneShotError:  false,
		podIdentityError:  true,
		preferredEndpoint: "ipv4",
		expError:          "failed to refresh cached credentials",
	}

	provider, closer := newPodIdentityCredentialWithMock(t, true, testData)
	defer func() { closer <- struct{}{} }()

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error during config creation, got: %v", err)
	}

	_, err = cfg.Credentials.Retrieve(context.Background())
	if err == nil {
		t.Fatalf("Expected error but got none")
	}

	if !strings.Contains(err.Error(), "failed to refresh cached credentials") {
		t.Errorf("Expected error containing 'failed to refresh cached credentials', got: %v", err)
	}
}

func TestPodIdentityCredentialProvider_IPv6Failure(t *testing.T) {
	defer resetEndpoints()

	testData := podIdentityCredentialTest{
		testName:          "IPv6 Failure",
		k8CTOneShotError:  false,
		podIdentityError:  true,
		preferredEndpoint: "ipv6",
		expError:          "failed to refresh cached credentials",
	}

	provider, closer := newPodIdentityCredentialWithMock(t, false, testData)
	defer func() { closer <- struct{}{} }()

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error during config creation, got: %v", err)
	}

	_, err = cfg.Credentials.Retrieve(context.Background())
	if err == nil {
		t.Fatalf("Expected error but got none")
	}

	if !strings.Contains(err.Error(), "failed to refresh cached credentials") {
		t.Errorf("Expected error containing 'failed to refresh cached credentials', got: %v", err)
	}
}

func TestPodIdentityCredentialProvider_AutoFailure(t *testing.T) {
	defer resetEndpoints()

	testData := podIdentityCredentialTest{
		testName:          "Auto Selection Failure",
		k8CTOneShotError:  false,
		podIdentityError:  true,
		preferredEndpoint: "auto",
		expError:          "failed to refresh cached credentials",
	}

	provider, closer := newPodIdentityCredentialWithMock(t, true, testData)
	defer func() { closer <- struct{}{} }()

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Expected no error during config creation, got: %v", err)
	}

	_, err = cfg.Credentials.Retrieve(context.Background())
	if err == nil {
		t.Fatalf("Expected error but got none")
	}

	if !strings.Contains(err.Error(), "failed to refresh cached credentials") {
		t.Errorf("Expected error containing 'failed to refresh cached credentials', got: %v", err)
	}
}

var podIdentityTokenTests = []podIdentityCredentialTest{
	{"Pod Identity Token Success with auto", false, true, false, "auto", ""},
	{"Pod Identity Token Success with IPv4", false, true, false, "ipv4", ""},
	{"Pod Identity Token Success with IPv6", false, true, false, "ipv6", ""},
	{"Pod Identity Token Success with empty preference", false, true, false, "", ""},
	{"Pod Identity Fetch JWT fail", true, true, false, "auto", "Fake create token"},
}

func TestPodIdentityToken(t *testing.T) {
	defer func() {
		podIdentityAgentEndpointIPv4 = defaultIPv4Endpoint
		podIdentityAgentEndpointIPv6 = defaultIPv6Endpoint
	}()

	for _, tstData := range podIdentityTokenTests {

		t.Run(tstData.testName, func(t *testing.T) {

			tstAuth, closer := newPodIdentityCredentialWithMock(t, tstData.preferredEndpoint == "ipv4", tstData)
			defer func() { closer <- struct{}{} }()
			fetcher := tstAuth.fetcher

			tokenOut, err := fetcher.GetToken()

			if len(tstData.expError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected error: %s", tstData.testName, err)
			}
			if len(tstData.expError) != 0 && err == nil {
				t.Errorf("%s case: expected error but got none", tstData.testName)
			}
			if len(tstData.expError) != 0 && !strings.HasPrefix(err.Error(), tstData.expError) {
				t.Errorf("%s case: expected error prefix '%s' but got '%s'", tstData.testName, tstData.expError, err.Error())
			}
			if len(tstData.expError) == 0 && len(tokenOut) == 0 {
				t.Errorf("%s case: got empty token output", tstData.testName)
				return
			}
			if len(tstData.expError) == 0 && string(tokenOut) != "FAKETOKEN" {
				t.Errorf("%s case: got bad token output", tstData.testName)
			}
		})

	}
}

func TestNewPodIdentityCredentialProviderTimeout(t *testing.T) {
	oneHundredMs := 100 * time.Millisecond
	oneSec := 1 * time.Second
	fiftyMs := 50 * time.Millisecond
	fiveSecs := 5 * time.Second

	tests := []struct {
		name                   string
		podIdentityHttpTimeout *time.Duration
		expectError            bool
	}{
		{
			name:                   "100ms timeout",
			podIdentityHttpTimeout: &oneHundredMs,
			expectError:            false,
		},
		{
			name:                   "1s timeout",
			podIdentityHttpTimeout: &oneSec,
			expectError:            false,
		},
		{
			name:                   "50ms timeout",
			podIdentityHttpTimeout: &fiftyMs,
			expectError:            false,
		},
		{
			name:                   "5s timeout",
			podIdentityHttpTimeout: &fiveSecs,
			expectError:            false,
		},
		{
			name:                   "nil timeout",
			podIdentityHttpTimeout: nil,
			expectError:            false,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			k8sClient := fake.NewSimpleClientset().CoreV1()

			provider, err := NewPodIdentityCredentialProvider(
				testRegion, testNamespace, testServiceAccount, testPodName, "", tt.podIdentityHttpTimeout, k8sClient)

			if tt.expectError && err == nil {
				t.Errorf("Expected error but got none")
			}
			if !tt.expectError && err != nil {
				t.Errorf("Unexpected error: %v", err)
			}

			if !tt.expectError && provider != nil {
				// Verify the timeout is set correctly by checking the HTTP client
				podProvider, ok := provider.(*PodIdentityCredentialProvider)
				if !ok {
					t.Error("Expected PodIdentityCredentialProvider type")
				} else if tt.podIdentityHttpTimeout != nil && podProvider.httpClient.GetTimeout() != *tt.podIdentityHttpTimeout {
					t.Errorf("Expected HTTP client timeout %v, got %v", tt.podIdentityHttpTimeout, podProvider.httpClient.GetTimeout())
				}
			}
		})
	}
}

func TestNewPodIdentityCredentialProviderValidation(t *testing.T) {
	tests := []struct {
		name                string
		region              string
		k8sClient           k8sv1.CoreV1Interface
		expectedErrorPrefix string
	}{
		{
			name:                "Empty region",
			region:              "",
			k8sClient:           fake.NewSimpleClientset().CoreV1(),
			expectedErrorPrefix: "region cannot be empty",
		},
		{
			name:                "Nil k8s client",
			region:              testRegion,
			k8sClient:           nil,
			expectedErrorPrefix: "k8s client cannot be nil",
		},
		{
			name:                "Valid parameters",
			region:              testRegion,
			k8sClient:           fake.NewSimpleClientset().CoreV1(),
			expectedErrorPrefix: "",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			provider, err := NewPodIdentityCredentialProvider(
				tt.region, testNamespace, testServiceAccount, testPodName, "", nil, tt.k8sClient)

			if tt.expectedErrorPrefix == "" {
				if err != nil {
					t.Errorf("Expected no error, got: %v", err)
				}
				if provider == nil {
					t.Error("Expected provider to be non-nil")
				}
			} else {
				if err == nil {
					t.Errorf("Expected error for %s, got nil", tt.name)
				} else if !strings.HasPrefix(err.Error(), tt.expectedErrorPrefix) {
					t.Errorf("Expected error prefix '%s', got: '%s'", tt.expectedErrorPrefix, err.Error())
				}
				if provider != nil {
					t.Error("Expected provider to be nil when error occurs")
				}
			}
		})
	}
}
