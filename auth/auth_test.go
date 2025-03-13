package auth

import (
	"context"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go/service/sts/stsiface"
	"k8s.io/client-go/kubernetes/fake"
)

// Mock STS client
type mockSTS struct {
	stsiface.STSAPI
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
		expError:        "failed to fetch token", // Pod Identity path will fail fetching token since using fake client
	},
}

func TestGetAWSSession(t *testing.T) {
	for _, tstData := range sessionTests {
		t.Run(tstData.testName, func(t *testing.T) {

			auth := &Auth{
				region:         "someRegion",
				nameSpace:      "someNamespace",
				svcAcc:         "someSvcAcc",
				podName:        "somepod",
				usePodIdentity: tstData.testPodIdentity,
				k8sClient:      fake.NewSimpleClientset().CoreV1(),
				stsClient:      &mockSTS{},
				ctx:            context.Background(),
			}

			sess, err := auth.GetAWSSession()

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
