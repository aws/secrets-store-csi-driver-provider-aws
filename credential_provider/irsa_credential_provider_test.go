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
	}
	if !tstData.k8SAGetOneShotError {
		sa.Name = testServiceAccount
	}
	clientset := fake.NewSimpleClientset(sa)
	if tstData.testToken {
		k8sClient = &mockK8sV1{
			clientset.CoreV1(),
			clientset.CoreV1(),
			tstData.k8CTOneShotError,
		}
	} else {
		sa.Namespace = testNamespace
		sa.Annotations = map[string]string{roleArnAnnotationKey: tstData.roleARN}
		k8sClient = clientset.CoreV1()
	}
	return &IRSACredentialProvider{
		stsClient:      &mockSTS{},
		k8sClient:      k8sClient,
		region:         testRegion,
		namespace:      testNamespace,
		serviceAccount: testServiceAccount,
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

func TestIRSACredentialProvider(t *testing.T) {
	cases := []irsaCredentialTest{
		{"IRSA Success", false, false, "fakeRoleARN", true, "", ""},
		{"IRSA Missing Role", false, false, "", false, "", "an IAM role must"},
		{"Fetch svc acc fail", true, false, "fakeRoleARN", false, "not found", ""},
	}
	for _, tt := range cases {
		t.Run(tt.testName, func(t *testing.T) {
			provider := newIRSACredentialProviderWithMock(tt)
			cfg, err := provider.GetAWSConfig(context.Background())
			if err != nil {
				if len(tt.cfgError) != 0 && !strings.Contains(err.Error(), tt.cfgError) {
					t.Errorf("%s case: expected error prefix '%s' but got '%s'", tt.testName, tt.cfgError, err.Error())
				}
				return
			}
			_, err = cfg.Credentials.Retrieve(context.Background())

			if len(tt.expError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected cred provider error: '%s'", tt.testName, err)
			}
			if cfg.Credentials == nil {
				t.Errorf("%s case: got empty cred provider in config", tt.testName)
			}
			if len(tt.expError) != 0 && err == nil {
				t.Errorf("%s case: expected error but got none", tt.testName)
			}
			if len(tt.expError) != 0 && !strings.Contains(err.Error(), tt.expError) {
				t.Errorf("%s case: expected error prefix '%s' but got '%s'", tt.testName, tt.expError, err.Error())
			}
		})
	}
}

func TestIRSAToken(t *testing.T) {

	cases := []irsaCredentialTest{
		{"IRSA Token Success", false, false, "myRoleARN", true, "", ""},
		{"IRSA Fetch JWT fail", false, true, "myRoleARN", true, "", "Fake create token"},
	}

	for _, tt := range cases {

		t.Run(tt.testName, func(t *testing.T) {

			tstAuth := newIRSACredentialProviderWithMock(tt)
			fetcher := tstAuth.fetcher

			tokenOut, err := fetcher.GetIdentityToken()

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
