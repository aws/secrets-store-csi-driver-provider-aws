package credential_provider

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

const (
	testPodName = "somePodName"
)

func setupMockPodIdentityAgent(shouldFail bool) *httptest.Server {
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
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
	}))
}

func newPodIdentityCredentialWithMock(tstData podIdentityCredentialTest) *PodIdentityCredentialProvider {
	k8sClient := &mockK8sV1{
		k8CTOneShotError: tstData.k8CTOneShotError,
	}

	mockServer := setupMockPodIdentityAgent(tstData.podIdentityError)
	podIdentityAgentEndpoint = mockServer.URL

	return &PodIdentityCredentialProvider{
		region:     testRegion,
		fetcher:    newPodIdentityTokenFetcher(testNamespace, testServiceAccount, testPodName, k8sClient),
		httpClient: mockServer.Client(),
	}
}

type podIdentityCredentialTest struct {
	testName         string
	k8CTOneShotError bool
	testToken        bool
	podIdentityError bool
	expError         string
}

var podIdentityCredentialTests []podIdentityCredentialTest = []podIdentityCredentialTest{
	{"Pod Identity Success", false, false, false, ""},
	{"Pod identity Failure", false, false, true, "pod identity agent returned error"},
}

func TestPodIdentityCredentialProvider(t *testing.T) {
	defer func() {
		podIdentityAgentEndpoint = defaultPodIdentityAgentEndpoint
	}()

	for _, tstData := range podIdentityCredentialTests {
		t.Run(tstData.testName, func(t *testing.T) {
			provider := newPodIdentityCredentialWithMock(tstData)
			config, err := provider.GetAWSConfig()

			if len(tstData.expError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected cred provider error: %s", tstData.testName, err)
			}
			if len(tstData.expError) == 0 && config == nil {
				t.Errorf("%s case: got empty config", tstData.testName)
			}
			if len(tstData.expError) != 0 && err == nil {
				t.Errorf("%s case: expected error but got none", tstData.testName)
			}
			if len(tstData.expError) != 0 && !strings.Contains(err.Error(), tstData.expError) {
				t.Errorf("%s case: expected error prefix '%s' but got '%s'", tstData.testName, tstData.expError, err.Error())
			}
		})
	}
}

func TestPodIdentityToken(t *testing.T) {
	defer func() {
		podIdentityAgentEndpoint = defaultPodIdentityAgentEndpoint
	}()

	for _, tstData := range podIdentityTokenTests {

		t.Run(tstData.testName, func(t *testing.T) {

			tstAuth := newPodIdentityCredentialWithMock(tstData)
			fetcher := tstAuth.fetcher

			tokenOut, err := fetcher.FetchToken(nil)

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

var podIdentityTokenTests []podIdentityCredentialTest = []podIdentityCredentialTest{
	{"Pod Identity Token Success", false, true, false, ""},
	{"Pod Identity Fetch JWT fail", true, true, false, "Fake create token"},
}

type podIdentityAgentEndpointTest struct {
	testName string
	podIP    string
	expIpv4  bool // true for expecting IPv4 endpoint, false for IPv6 endpoint
}

var endpointTests []podIdentityAgentEndpointTest = []podIdentityAgentEndpointTest{
	{"IPv4", "10.0.0.1", true},
	{"IPv6", "2001:db8::1", false},
	{"Bad IP", "10.0.0", true},
	{"Empty POD_IP", "", true},
}

func TestPodIdentityAgentEndpoint(t *testing.T) {
	defer func() {
		podIdentityAgentEndpoint = defaultPodIdentityAgentEndpoint
	}()

	for _, tt := range endpointTests {
		t.Run(tt.testName, func(t *testing.T) {
			// Set environment variable for test
			if tt.podIP != "" {
				os.Setenv("POD_IP", tt.podIP)
				defer os.Unsetenv("POD_IP")
			} else {
				os.Unsetenv("POD_IP")
			}

			// Re-initialize the endpoint for this test
			endpoint := func() string {
				isIPv6, err := isIPv6()
				if err != nil {
					return podIdentityAgentEndpointIPv4
				}
				if isIPv6 {
					return podIdentityAgentEndpointIPv6
				}
				return podIdentityAgentEndpointIPv4
			}()

			// Determine expected endpoint
			wantEndpoint := podIdentityAgentEndpointIPv4
			if !tt.expIpv4 {
				wantEndpoint = podIdentityAgentEndpointIPv6
			}

			if endpoint != wantEndpoint {
				t.Errorf("defaultPodIdentityAgentEndpoint = %v, want %v", endpoint, wantEndpoint)
			}
		})
	}
}
