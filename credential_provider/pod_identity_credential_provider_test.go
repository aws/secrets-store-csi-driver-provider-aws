package credential_provider

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func setupMockPodIdentityAgent(t *testing.T, isIPv4, shouldFail bool) *httptest.Server {
	t.Helper()
	var listener net.Listener
	if isIPv4 {
		listener, _ = net.Listen("tcp", "127.0.0.1:0")
	} else {
		listener, _ = net.Listen("tcp", "[::1]:0")
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
	t.Helper()

	mockServer := setupMockPodIdentityAgent(t, isIPv4, tstData.podIdentityError)
	respChan := make(chan struct{})
	go func(srv *httptest.Server) {
		<-respChan
		srv.Close()
	}(mockServer)
	var credentialEndpoint string
	if isIPv4 {
		credentialEndpoint = mockServer.URL
		podIdentityAgentEndpointIPv4 = mockServer.URL
	} else {
		credentialEndpoint = mockServer.URL
		podIdentityAgentEndpointIPv6 = mockServer.URL
	}

	fetcher := NewMockTokenFetcher("FAKETOKEN", nil)
	if tstData.podIdentityError {
		fetcher = NewMockTokenFetcher("", fmt.Errorf("failed to get token"))
	}

	return &PodIdentityCredentialProvider{
		region:             testRegion,
		credentialEndpoint: credentialEndpoint,
		fetcher:            fetcher,
		httpClient:         http.DefaultClient,
	}, respChan
}

type podIdentityCredentialTest struct {
	testName          string
	podIdentityError  bool
	preferredEndpoint string
	expError          string
}

func TestPodIdentityCredentialProvider(t *testing.T) {
	cases := []podIdentityCredentialTest{
		{"Pod Identity Success via IPv4", false, "ipv4", ""},
		{"Pod Identity Success via IPv6", false, "ipv6", ""},
		{"Pod Identity Success via auto selection", false, "auto", ""},
		{"Pod identity Failure via IPv4", true, "ipv4", "failed to refresh cached credentials, failed to load credentials"},
		{"Pod identity Failure via IPv6", true, "ipv6", "failed to refresh cached credentials, failed to load credentials"},
		{"Pod identity Failure via auto selection", true, "auto", "failed to refresh cached credentials, failed to load credentials"},
	}

	for _, tt := range cases {
		t.Run(tt.testName, func(t *testing.T) {
			provider, closer := newPodIdentityCredentialWithMock(t, tt.preferredEndpoint == "ipv4", tt)
			defer func() { closer <- struct{}{} }()

			cfg, _ := provider.GetAWSConfig(context.Background())
			_, err := cfg.Credentials.Retrieve(context.Background())

			if len(tt.expError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected cred provider error: %s", tt.testName, err)
			}
			if len(tt.expError) == 0 && cfg.Credentials == nil {
				t.Errorf("%s case: got empty credential provider", tt.testName)
			}
			if len(tt.expError) != 0 && err == nil {
				t.Fatalf("%s case: expected error but got none", tt.testName)
			}
			if len(tt.expError) != 0 && !strings.Contains(err.Error(), tt.expError) {
				t.Errorf("%s case: expected error prefix '%s' but got '%s'", tt.testName, tt.expError, err.Error())
			}
		})
	}
}

func TestPodIdentityToken(t *testing.T) {
	cases := []podIdentityCredentialTest{
		{"Pod Identity Token Success", false, "", ""},
		{"Pod Identity Fetch JWT fail", true, "", "failed to get token"},
	}

	for _, tt := range cases {

		t.Run(tt.testName, func(t *testing.T) {

			tstAuth, closer := newPodIdentityCredentialWithMock(t, tt.preferredEndpoint == "ipv4", tt)
			defer func() { closer <- struct{}{} }()
			fetcher := tstAuth.fetcher

			tokenOut, err := fetcher.GetToken()

			if len(tt.expError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected error: %s", tt.testName, err)
			}
			if len(tt.expError) != 0 && err == nil {
				t.Errorf("%s case: expected error but got none", tt.testName)
			}
			if len(tt.expError) != 0 && !strings.HasPrefix(err.Error(), tt.expError) {
				t.Errorf("%s case: expected error prefix '%s' but got '%s'", tt.testName, tt.expError, err.Error())
			}
			if len(tt.expError) == 0 && len(tokenOut) == 0 {
				t.Errorf("%s case: got empty token output", tt.testName)
				return
			}
			if len(tt.expError) == 0 && string(tokenOut) != "FAKETOKEN" {
				t.Errorf("%s case: got bad token output", tt.testName)
			}
		})

	}
}
