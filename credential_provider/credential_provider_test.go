package credential_provider

import (
	"context"
	"fmt"
	"github.com/aws/aws-sdk-go/service/sts/stsiface"
	authv1 "k8s.io/api/authentication/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	k8sv1 "k8s.io/client-go/kubernetes/typed/core/v1"
)

const (
	testNamespace      = "someNamespace"
	testServiceAccount = "someServiceAccount"
	testRegion         = "someRegion"
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
