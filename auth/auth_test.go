package auth

import (
	"context"
	"fmt"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go/service/sts/stsiface"

	authv1 "k8s.io/api/authentication/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
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

func newAuthWithMocks(k8SAGetError bool, roleARN string) *Auth {

	nameSpace := "someNamespace"
	accName := "someServiceAccount"
	region := "someRegion"

	sa := &corev1.ServiceAccount{}
	if !k8SAGetError {
		sa.Name = accName
	}
	sa.Namespace = nameSpace
	sa.Annotations = map[string]string{"eks.amazonaws.com/role-arn": roleARN}

	clientset := fake.NewSimpleClientset(sa)

	return &Auth{
		region:    region,
		nameSpace: nameSpace,
		svcAcc:    accName,
		k8sClient: clientset.CoreV1(),
		stsClient: &mockSTS{},
	}

}

type authTest struct {
	testName            string
	k8SAGetOneShotError bool
	k8CTOneShotError    bool
	roleARN             string
	expError            string
}

var authTests []authTest = []authTest{
	{"Success", false, false, "fakeRoleARN", ""},
	{"Missing Role", false, false, "", "An IAM role must"},
	{"Fetch svc acc fail", true, false, "fakeRoleARN", "not found"},
}

func TestAuth(t *testing.T) {

	for _, tstData := range authTests {

		t.Run(tstData.testName, func(t *testing.T) {

			tstAuth := newAuthWithMocks(tstData.k8SAGetOneShotError, tstData.roleARN)
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
	{"Success", false, false, "myRoleARN", ""},
	{"Fetch JWT fail", false, true, "myRoleARN", "Fake create token"},
}

func TestToken(t *testing.T) {

	for _, tstData := range tokenTests {

		t.Run(tstData.testName, func(t *testing.T) {

			tstAuth := newAuthWithMocks(tstData.k8SAGetOneShotError, tstData.roleARN)
			fetcher := &authTokenFetcher{tstAuth.nameSpace, tstAuth.svcAcc, &mockK8sV1{k8CTOneShotError: tstData.k8CTOneShotError}}
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
