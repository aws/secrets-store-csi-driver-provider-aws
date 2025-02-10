package credential_provider

import (
	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes/fake"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
	"strings"
	"testing"
)

const (
	roleArnAnnotationKey = "eks.amazonaws.com/role-arn"
)

func newIRSACredentialProviderWithMock(tstData irsaCredentialTest) *IRSACredentialProvider {
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

type irsaCredentialTest struct {
	testName            string
	k8SAGetOneShotError bool
	k8CTOneShotError    bool
	roleARN             string
	testToken           bool
	expError            string
}

var irsaCredentialTests []irsaCredentialTest = []irsaCredentialTest{
	{"IRSA Success", false, false, "fakeRoleARN", false, ""},
	{"IRSA Missing Role", false, false, "", false, "An IAM role must"},
	{"Fetch svc acc fail", true, false, "fakeRoleARN", false, "not found"},
}

func TestIRSACredentialProvider(t *testing.T) {
	for _, tstData := range irsaCredentialTests {
		t.Run(tstData.testName, func(t *testing.T) {
			provider := newIRSACredentialProviderWithMock(tstData)
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

func TestIRSAToken(t *testing.T) {
	for _, tstData := range irsaTokenTests {

		t.Run(tstData.testName, func(t *testing.T) {

			tstAuth := newIRSACredentialProviderWithMock(tstData)
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

var irsaTokenTests []irsaCredentialTest = []irsaCredentialTest{
	{"IRSA Token Success", false, false, "myRoleARN", true, ""},
	{"IRSA Fetch JWT fail", false, true, "myRoleARN", true, "Fake create token"},
}

