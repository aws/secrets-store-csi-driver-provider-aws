package credential_provider

import (
	"fmt"
	"net/http"
	"net/http/httptest"
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
	podIdentityAgentEndpointIPv4 = mockServer.URL
	podIdentityAgentEndpointIPv6 = mockServer.URL

	return &PodIdentityCredentialProvider{
		region:     testRegion,
		fetcher:    newPodIdentityTokenFetcher(testNamespace, testServiceAccount, testPodName, k8sClient),
		httpClient: mockServer.Client(),
	}
}

type podIdentityCredentialTest struct {
	testName          string
	k8CTOneShotError  bool
	testToken         bool
	podIdentityError  bool
	preferredEndpoint endpointPreference
	expError          string
}

var podIdentityCredentialTests []podIdentityCredentialTest = []podIdentityCredentialTest{
	{"Pod Identity Success via IPv4", false, false, false, preferenceIPv4, ""},
	{"Pod Identity Success via IPv6", false, false, false, preferenceIPv6, ""},
	{"Pod Identity Success via auto selection", false, false, false, preferenceAuto, ""},
	{"Pod identity Failure via IPv4", false, false, true, preferenceIPv4, "pod identity agent returned error"},
	{"Pod identity Failure via IPv6", false, false, true, preferenceIPv6, "pod identity agent returned error"},
	{"Pod identity Failure via auto selection", false, false, true, preferenceAuto, "pod identity agent returned error"},
}

func TestPodIdentityCredentialProvider(t *testing.T) {
	defer func() {
		podIdentityAgentEndpointIPv4 = defaultIPv4Endpoint
		podIdentityAgentEndpointIPv6 = defaultIPv6Endpoint
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
		podIdentityAgentEndpointIPv4 = defaultIPv4Endpoint
		podIdentityAgentEndpointIPv6 = defaultIPv6Endpoint
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
	{"Pod Identity Token Success", false, true, false, preferenceAuto, ""},
	{"Pod Identity Fetch JWT fail", true, true, false, preferenceAuto, "Fake create token"},
}

type podIdentityAgentEndpointTest struct {
	testName             string
	preferredAddressType string
	expected             endpointPreference
}

var endpointTests []podIdentityAgentEndpointTest = []podIdentityAgentEndpointTest{
	{"PreferredAddressType not provided", "", preferenceAuto},
	{"ipv4", "ipv4", preferenceIPv4},
	{"IPv4", "IPv4", preferenceIPv4},
	{"ipv6", "ipv6", preferenceIPv6},
	{"IPv6", "IPv6", preferenceIPv6},
	{"Invalid PreferredAddressType", "invalid", preferenceAuto},
}

func TestPodIdentityAgentEndpoint(t *testing.T) {

	for _, tt := range endpointTests {
		t.Run(tt.testName, func(t *testing.T) {
			endpoint := parseAddressPreference(tt.preferredAddressType)

			if endpoint != tt.expected {
				t.Errorf("defaultPodIdentityAgentEndpoint = %v, want %v", endpoint, tt.expected)
			}
		})
	}
}
