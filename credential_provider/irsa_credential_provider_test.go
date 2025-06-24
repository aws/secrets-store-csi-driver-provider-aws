package credential_provider

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/aws-sdk-go-v2/service/sts/types"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes/fake"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
)

const (
	roleArnAnnotationKey = "eks.amazonaws.com/role-arn"
	testNamespace        = "someNamespace"
	testServiceAccount   = "someServiceAccount"
	testRegion           = "someRegion"
)

// Mock STS client
type mockSTS struct {
	sts.Client
}

func (m *mockSTS) AssumeRoleWithWebIdentity(context.Context, *sts.AssumeRoleWithWebIdentityInput, ...func(*sts.Options)) (*sts.AssumeRoleWithWebIdentityOutput, error) {
	return &sts.AssumeRoleWithWebIdentityOutput{
		Credentials: &types.Credentials{
			AccessKeyId:     aws.String("TEST_ACCESS_KEY"),
			SecretAccessKey: aws.String("TEST_SECRET"),
			SessionToken:    aws.String("TEST_TOKEN"),
			Expiration:      aws.Time(time.Now().Add(time.Hour * 1)),
		},
	}, nil
}

func newIRSACredentialProviderWithMock(tstData irsaCredentialTest, tokenFetcher TokenFetcher) ConfigProvider {
	var k8sClient k8sv1.CoreV1Interface
	clientset := fake.NewClientset()
	if !tstData.k8SAGetOneShotError {
		sa := &corev1.ServiceAccount{
			TypeMeta: metav1.TypeMeta{
				Kind:       "ServiceAccount",
				APIVersion: "v1",
			},
			ObjectMeta: metav1.ObjectMeta{
				Name:      testServiceAccount,
				Namespace: testNamespace,
				Annotations: map[string]string{
					roleArnAnnotationKey: tstData.roleARN,
				},
			},
		}
		clientset = fake.NewClientset(sa)
	}
	k8sClient = clientset.CoreV1()
	return NewIRSACredentialProvider(
		testRegion,
		testNamespace,
		testServiceAccount,
		&mockSTS{},
		k8sClient,
		tokenFetcher,
	)
}

type irsaCredentialTest struct {
	testName            string
	tokenFetcher        TokenFetcher
	k8SAGetOneShotError bool
	roleARN             string
	cfgError            string
	expError            string
}

func TestIRSACredentialProvider(t *testing.T) {
	cases := []irsaCredentialTest{
		{"IRSA Success", NewMockTokenFetcher("FAKETOKEN", nil), false, "fakeRoleARN", "", ""},
		{"IRSA Missing Role", NewMockTokenFetcher("FAKETOKEN", nil), false, "", "", "an IAM role must"},
		{"Fetch svc acc fail", NewMockTokenFetcher("FAKETOKEN", nil), true, "fakeRoleARN", "not found", ""},
	}
	for _, tt := range cases {
		t.Run(tt.testName, func(t *testing.T) {
			provider := newIRSACredentialProviderWithMock(tt, tt.tokenFetcher)
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
