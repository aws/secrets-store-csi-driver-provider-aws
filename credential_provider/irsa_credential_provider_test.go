package credential_provider

import (
	"context"
	"strings"
	"testing"

	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
)

const (
	roleArnAnnotationKey = "eks.amazonaws.com/role-arn"
)

func newIRSACredentialProviderWithMock(tstData irsaCredentialTest) *IRSACredentialProvider {
	var k8sClient k8sv1.CoreV1Interface
	sa := &corev1.ServiceAccount{
		TypeMeta: metav1.TypeMeta{
			Kind:       "ServiceAccount",
			APIVersion: "v1",
		},
		ObjectMeta: metav1.ObjectMeta{
			Name:      testServiceAccount,
			Namespace: testNamespace,
		},
	}
	if !tstData.k8SAGetOneShotError {
		if !tstData.testToken {
			sa.Annotations = map[string]string{roleArnAnnotationKey: tstData.roleARN}
		}
	}
	clientset := fake.NewSimpleClientset(sa)
	if tstData.testToken {
		k8sClient = &mockK8sV1{
			CoreV1Interface:  clientset.CoreV1(),
			fake:             clientset.CoreV1(),
			k8CTOneShotError: tstData.k8CTOneShotError,
		}
	} else {
		k8sClient = clientset.CoreV1()
	}
	return &IRSACredentialProvider{
		stsClient: &mockSTS{},
		k8sClient: k8sClient,
		region:    testRegion,
		nameSpace: testNamespace,
		svcAcc:    testServiceAccount,
		appID:     "test-app-id",
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
	cfgError            string
	expError            string
}

var irsaCredentialTests []irsaCredentialTest = []irsaCredentialTest{
	{"IRSA Success", false, false, "fakeRoleARN", true, "", ""},
	{"IRSA Missing Role", false, false, "", false, "", "An IAM role must"},
	{"Fetch svc acc fail", true, false, "fakeRoleARN", false, "not found", ""},
}

func TestIRSACredentialProvider(t *testing.T) {
	for _, tstData := range irsaCredentialTests {
		t.Run(tstData.testName, func(t *testing.T) {
			provider := newIRSACredentialProviderWithMock(tstData)
			cfg, err := provider.GetAWSConfig(context.Background())
			if err != nil {
				if len(tstData.expError) > 0 && !strings.Contains(err.Error(), tstData.expError) {
					t.Errorf("%s case: expected error prefix '%s' but got '%s'", tstData.testName, tstData.expError, err.Error())
				}
				return
			}

			_, err = cfg.Credentials.Retrieve(context.Background())
			if len(tstData.expError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected cred provider error: %s", tstData.testName, err)
			}
			if cfg.Credentials == nil {
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

			tokenOut, err := fetcher.GetIdentityToken()

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
	{"IRSA Token Success", false, false, "myRoleARN", true, "", ""},
	{"IRSA Fetch JWT fail", false, true, "myRoleARN", true, "", "Fake create token"},
}

func TestNewIRSACredentialProvider_AppID(t *testing.T) {
	expectedAppID := "test-app-id"
	k8sClient := fake.NewSimpleClientset().CoreV1()

	provider := NewIRSACredentialProvider(
		&mockSTS{},
		testRegion,
		testNamespace,
		testServiceAccount,
		expectedAppID,
		k8sClient,
	)

	irsaProvider, ok := provider.(*IRSACredentialProvider)
	if !ok {
		t.Fatal("Expected IRSACredentialProvider type")
	}

	if irsaProvider.appID != expectedAppID {
		t.Errorf("Expected appID %q, got %q", expectedAppID, irsaProvider.appID)
	}
}
