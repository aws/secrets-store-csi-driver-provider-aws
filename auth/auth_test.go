package auth

import (
	"context"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/service/sts"
	"k8s.io/client-go/kubernetes/fake"
)

// Mock STS client
type mockSTS struct {
	sts.Client
}

func (m *mockSTS) AssumeRoleWithWebIdentity(ctx context.Context, params *sts.AssumeRoleWithWebIdentityInput, optFns ...func(*sts.Options)) (*sts.AssumeRoleWithWebIdentityOutput, error) {
	return nil, fmt.Errorf("fake error for serviceaccount")
}

type sessionTest struct {
	testName        string
	testPodIdentity bool
	expError        string
}

var sessionTests []sessionTest = []sessionTest{
	{
		testName:        "IRSA",
		testPodIdentity: false,
		expError:        "serviceaccounts", // IRSA path will fail at getting service account since using fake client
	},
	{
		testName:        "Pod Identity",
		testPodIdentity: true,
		expError:        "", // Pod Identity path succeeds since token is lazy loaded
	},
}

func TestGetAWSConfig(t *testing.T) {
	for _, tstData := range sessionTests {
		t.Run(tstData.testName, func(t *testing.T) {

			auth := &Auth{
				region:         "someRegion",
				nameSpace:      "someNamespace",
				svcAcc:         "someSvcAcc",
				podName:        "somepod",
				usePodIdentity: tstData.testPodIdentity,
				httpTimeout:    100 * time.Millisecond,
				k8sClient:      fake.NewSimpleClientset().CoreV1(),
				stsClient:      &mockSTS{},
			}

			cfg, err := auth.GetAWSConfig(context.Background())

			if len(tstData.expError) == 0 && err != nil {
				t.Errorf("%s case: got unexpected auth error: %s", tstData.testName, err)
			}
			if len(tstData.expError) == 0 && cfg.Credentials == nil {
				t.Errorf("%s case: got empty session", tstData.testName)
			}
			if len(tstData.expError) != 0 && err == nil {
				t.Errorf("%s case: expected error but got none", tstData.testName)
			}
			if len(tstData.expError) != 0 && err != nil && !strings.Contains(err.Error(), tstData.expError) {
				t.Errorf("%s case: expected error prefix '%s' but got '%s'", tstData.testName, tstData.expError, err.Error())
			}
		})
	}
}
