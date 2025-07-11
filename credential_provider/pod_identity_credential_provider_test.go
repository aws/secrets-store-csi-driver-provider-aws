package credential_provider

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"k8s.io/client-go/kubernetes/fake"
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
		httpClient:           http.DefaultClient,
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

var podIdentityCredentialTests []podIdentityCredentialTest = []podIdentityCredentialTest{
	{"Pod Identity Success via IPv4", false, false, false, "ipv4", ""},
	{"Pod Identity Success via IPv6", false, false, false, "ipv6", ""},
	{"Pod Identity Success via auto selection", false, false, false, "auto", ""},
	{"Pod identity Failure via IPv4", false, false, true, "ipv4", "failed to refresh cached credentials"},
	{"Pod identity Failure via IPv6", false, false, true, "ipv6", "failed to refresh cached credentials"},
	{"Pod identity Failure via auto selection", false, false, true, "auto", "failed to refresh cached credentials"},
}

func TestPodIdentityCredentialProvider(t *testing.T) {
	defer func() {
		podIdentityAgentEndpointIPv4 = defaultIPv4Endpoint
		podIdentityAgentEndpointIPv6 = defaultIPv6Endpoint
	}()

	for _, tstData := range podIdentityCredentialTests {
		t.Run(tstData.testName, func(t *testing.T) {
			isIPv4 := tstData.preferredEndpoint == "ipv4" ||
				(tstData.preferredEndpoint == "auto" && !tstData.podIdentityError)

			provider, closer := newPodIdentityCredentialWithMock(t, isIPv4, tstData)
			defer func() { closer <- struct{}{} }()

			cfg, err := provider.GetAWSConfig(context.Background())
			if err != nil {
				if len(tstData.expError) == 0 {
					t.Errorf("%s case: unexpected error: %v", tstData.testName, err)
				}
				return
			}

			creds, err := cfg.Credentials.Retrieve(context.Background())
			if err != nil {
				if len(tstData.expError) == 0 {
					t.Errorf("%s case: unexpected credential retrieval error: %v", tstData.testName, err)
				} else if !strings.Contains(err.Error(), tstData.expError) {
					t.Errorf("%s case: error message '%s' does not contain expected text '%s'",
						tstData.testName, err.Error(), tstData.expError)
				}
				return
			}

			// Only check credentials if we're not expecting an error
			if len(tstData.expError) == 0 {
				if creds.AccessKeyID != "TEST_ACCESS_KEY" ||
					creds.SecretAccessKey != "TEST_SECRET" ||
					creds.SessionToken != "TEST_TOKEN" {
					t.Errorf("%s case: unexpected credentials", tstData.testName)
				}
			}
		})
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
