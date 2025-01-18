package credential_provider

import (
	"context"
	"fmt"
	"github.com/aws/aws-sdk-go/service/sts/stsiface"
	authv1 "k8s.io/api/authentication/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

const (
	testNamespace        = "someNamespace"
	testServiceAccount   = "someServiceAccount"
	testRegion           = "someRegion"
	testPodName          = "somePodName"
	roleArnAnnotationKey = "eks.amazonaws.com/role-arn"
)

// Mock STS client
type mockSTS struct {
	stsiface.STSAPI
}

// Mock K8s client for creating tokens
type mockK8sV1 struct {
	k8sv1.CoreV1Interface
	k8CTOneShotError bool
}

func (m *mockK8sV1) ServiceAccounts(namespace string) k8sv1.ServiceAccountInterface {
	return &mockK8sV1SA{v1mock: m}
}

// Mock the K8s service account client
type mockK8sV1SA struct {
	k8sv1.ServiceAccountInterface
	v1mock *mockK8sV1
}

func (ma *mockK8sV1SA) CreateToken(
	ctx context.Context,
	serviceAccountName string,
	tokenRequest *authv1.TokenRequest,
	opts metav1.CreateOptions,
) (*authv1.TokenRequest, error) {

	if ma.v1mock.k8CTOneShotError {
		ma.v1mock.k8CTOneShotError = false // Reset so other tests don't fail
		return nil, fmt.Errorf("Fake create token error")
	}

	return &authv1.TokenRequest{
		Status: authv1.TokenRequestStatus{
			Token: "FAKETOKEN",
		},
	}, nil
}

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

func newPodIdentityCredentialWithMock(tstData credentialTest) CredentialProvider {
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

func newIRSACredentialProviderWithMock(tstData credentialTest) CredentialProvider {
	var k8sClient k8sv1.CoreV1Interface
	sa := &corev1.ServiceAccount{}
	if !tstData.k8SAGetOneShotError {
		sa.Name = testServiceAccount
	}

	if tstData.testToken {
		k8sClient = &mockK8sV1{
			k8CTOneShotError: tstData.k8CTOneShotError,
		}
	} else {
		sa.Namespace = testNamespace
		sa.Annotations = map[string]string{roleArnAnnotationKey: tstData.roleARN}
		clientset := fake.NewSimpleClientset(sa)
		k8sClient = clientset.CoreV1()
	}
	return &IRSACredentialProvider{
		stsClient: &mockSTS{},
		k8sClient: k8sClient,
		region:    testRegion,
		nameSpace: testNamespace,
		svcAcc:    testServiceAccount,
		fetcher: newIRSATokenFetcher(
			testNamespace,
			testServiceAccount,
			k8sClient,
		),
	}
}

func newCredentialProviderWithMocks(tstData credentialTest) CredentialProvider {
	if tstData.testPodIdentity {
		return newPodIdentityCredentialWithMock(tstData)
	}
	return newIRSACredentialProviderWithMock(tstData)
}

type credentialTest struct {
	testName            string
	k8SAGetOneShotError bool
	k8CTOneShotError    bool
	roleARN             string
	testToken           bool
	testPodIdentity     bool
	podIdentityError    bool
	expError            string
}

var credentialTests []credentialTest = []credentialTest{
	{"IRSA Success", false, false, "fakeRoleARN", false, false, false, ""},
	{"IRSA Missing Role", false, false, "", false, false, false, "An IAM role must"},
	{"Fetch svc acc fail", true, false, "fakeRoleARN", false, false, false, "not found"},
	{"Pod Identity Success", false, false, "", false, true, false, ""},
	{"Pod identity Failure", false, false, "", false, true, true, "pod identity agent returned error"},
}

func TestCredentialProvider(t *testing.T) {
	defer func() {
		podIdentityAgentEndpoint = defaultPodIdentityAgentEndpoint
	}()

	for _, tstData := range credentialTests {
		t.Run(tstData.testName, func(t *testing.T) {
			provider := newCredentialProviderWithMocks(tstData)
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

func TestToken(t *testing.T) {
	defer func() {
		podIdentityAgentEndpoint = defaultPodIdentityAgentEndpoint
	}()

	for _, tstData := range tokenTests {

		t.Run(tstData.testName, func(t *testing.T) {

			tstAuth := newCredentialProviderWithMocks(tstData)
			var fetcher authTokenFetcher
			if tstData.testPodIdentity {
				fetcher = tstAuth.(*PodIdentityCredentialProvider).fetcher.(*podIdentityTokenFetcher)
			} else {
				fetcher = tstAuth.(*IRSACredentialProvider).fetcher.(*irsaTokenFetcher)
			}

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

var tokenTests []credentialTest = []credentialTest{
	{"IRSA Token Success", false, false, "myRoleARN", true, false, false, ""},
	{"IRSA Fetch JWT fail", false, true, "myRoleARN", true, false, false, "Fake create token"},
	{"Pod Identity Token Success", false, false, "", true, true, false, ""},
	{"Pod Identity Fetch JWT fail", false, true, "", true, true, false, "Fake create token"},
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
