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

	var credentialEndpoint string
	if isIPv4 {
		credentialEndpoint = mockServer.URL
		podIdentityAgentEndpointIPv4 = mockServer.URL
	} else {
		credentialEndpoint = mockServer.URL
		podIdentityAgentEndpointIPv6 = mockServer.URL
	}

	return &PodIdentityCredentialProvider{
		region:             testRegion,
		credentialEndpoint: credentialEndpoint,
		fetcher:            newPodIdentityTokenFetcher(testNamespace, testServiceAccount, testPodName, k8sClient),
		httpClient:         http.DefaultClient,
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
	{"Pod identity Failure via IPv4", false, false, true, "ipv4", "failed to refresh cached credentials, failed to load credentials, exceeded maximum number of attempts, 3, : "},
	{"Pod identity Failure via IPv6", false, false, true, "ipv6", "failed to refresh cached credentials, failed to load credentials, exceeded maximum number of attempts, 3, : "},
	{"Pod identity Failure via auto selection", false, false, true, "auto", "failed to refresh cached credentials, failed to load credentials, exceeded maximum number of attempts, 3, : "},
}

func TestPodIdentityCredentialProvider(t *testing.T) {
	for _, tstData := range podIdentityCredentialTests {
		t.Run(tstData.testName, func(t *testing.T) {
			provider, closer := newPodIdentityCredentialWithMock(t, tstData.preferredEndpoint == "ipv4", tstData)
			defer func() { closer <- struct{}{} }()

			cfg, _ := provider.GetAWSConfig(context.Background())
			_, err := cfg.Credentials.Retrieve(context.Background())

			if len(tstData.expError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected cred provider error: %s", tstData.testName, err)
			}
			if len(tstData.expError) == 0 && cfg.Credentials == nil {
				t.Errorf("%s case: got empty credential provider", tstData.testName)
			}
			if len(tstData.expError) != 0 && err == nil {
				t.Fatalf("%s case: expected error but got none", tstData.testName)
			}
			if len(tstData.expError) != 0 && !strings.Contains(err.Error(), tstData.expError) {
				t.Errorf("%s case: expected error prefix '%s' but got '%s'", tstData.testName, tstData.expError, err.Error())
			}
		})
	}
}

var podIdentityTokenTests = []podIdentityCredentialTest{
	{"Pod Identity Token Success", false, true, false, "auto", ""},
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
