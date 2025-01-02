package auth

import (
	"context"
	"fmt"
	"k8s.io/client-go/kubernetes/fake"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go/service/sts/stsiface"

	authv1 "k8s.io/api/authentication/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
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

func newAuthWithMocks(k8SAGetError bool, roleARN string, testPodIdentity bool) *Auth {

	nameSpace := "someNamespace"
	accName := "someServiceAccount"
	region := "someRegion"
	podName := "somePodName"

	var k8sClient k8sv1.CoreV1Interface

	if testPodIdentity {
		// Use mock client for Pod Identity tests
		mockV1 := &mockK8sV1{
			k8CTOneShotError: k8SAGetError,
		}
		k8sClient = mockV1

	} else {
		sa := &corev1.ServiceAccount{}
		if !k8SAGetError {
			sa.Name = accName
		}
		sa.Namespace = nameSpace
		sa.Annotations = map[string]string{"eks.amazonaws.com/role-arn": roleARN}

		clientset := fake.NewSimpleClientset(sa)
		k8sClient = clientset.CoreV1()
	}

	return &Auth{
		region:         region,
		nameSpace:      nameSpace,
		svcAcc:         accName,
		podName:        podName,
		usePodIdentity: testPodIdentity,
		k8sClient:      k8sClient,
		stsClient:      &mockSTS{},
	}
}

type authTest struct {
	testName            string
	k8SAGetOneShotError bool
	k8CTOneShotError    bool
	roleARN             string
	testPodIdentity     bool
	podIdentityError    bool
	expError            string
}

var authTests []authTest = []authTest{
	{"IRSA Success", false, false, "fakeRoleARN", false, false, ""},
	{"IRSA Missing Role", false, false, "", false, false, "An IAM role must"},
	{"Fetch svc acc fail", true, false, "fakeRoleARN", false, false, "not found"},
	{"Pod Identity Success", false, false, "", true, false, ""},
	{"Pod identity Failure", false, false, "", true, true, "pod identity agent returned error"},
}

func TestAuth(t *testing.T) {
	defer func() {
		podIdentityAgentEndpoint = defaultPodIdentityAgentEndpoint
	}()

	for _, tstData := range authTests {

		t.Run(tstData.testName, func(t *testing.T) {

			var mockPodIdentityServer *httptest.Server
			if tstData.testPodIdentity {
				mockPodIdentityServer = setupMockPodIdentityAgent(tstData.podIdentityError)
				defer mockPodIdentityServer.Close()
				// Override the endpoint for testing
				podIdentityAgentEndpoint = mockPodIdentityServer.URL
			}

			tstAuth := newAuthWithMocks(tstData.k8SAGetOneShotError, tstData.roleARN, tstData.testPodIdentity)

			sess, err := tstAuth.GetAWSSession()

			if len(tstData.expError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected auth error: %s", tstData.testName, err)
			}
			if len(tstData.expError) == 0 && sess == nil {
				t.Errorf("%s case: got empty session", tstData.testName)
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

var tokenTests []authTest = []authTest{
	{"IRSA Token Success", false, false, "myRoleARN", false, false, ""},
	{"Fetch JWT fail", false, true, "myRoleARN", false, false, "Fake create token"},
	{"Pod Identity Token Success", false, false, "", true, false, ""},
}

func TestToken(t *testing.T) {

	for _, tstData := range tokenTests {

		t.Run(tstData.testName, func(t *testing.T) {

			tstAuth := newAuthWithMocks(tstData.k8SAGetOneShotError, tstData.roleARN, tstData.testPodIdentity)
			fetcher := &authTokenFetcher{tstAuth.nameSpace, tstAuth.svcAcc, tstAuth.podName, &mockK8sV1{k8CTOneShotError: tstData.k8CTOneShotError}, tstAuth.usePodIdentity}
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
