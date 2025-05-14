package credential_provider

import (
	"context"
	"fmt"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/aws-sdk-go-v2/service/sts/types"
	
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
	sts.Client
}

func (m *mockSTS) AssumeRoleWithWebIdentity(ctx context.Context, params *sts.AssumeRoleWithWebIdentityInput, optFns ...func(*sts.Options)) (*sts.AssumeRoleWithWebIdentityOutput, error) {
	return &sts.AssumeRoleWithWebIdentityOutput{
		Credentials: &types.Credentials{
			AccessKeyId:     aws.String("TEST_ACCESS_KEY"),
			SecretAccessKey: aws.String("TEST_SECRET"),
			SessionToken:    aws.String("TEST_TOKEN"),
		},
	}, nil
}

// Mock K8s client for creating tokens
type mockK8sV1 struct {
	k8sv1.CoreV1Interface
	fake k8sv1.CoreV1Interface
	k8CTOneShotError bool
}

func (m *mockK8sV1) ServiceAccounts(namespace string) k8sv1.ServiceAccountInterface {
	return &mockK8sV1SA{
        ServiceAccountInterface: m.fake.ServiceAccounts(namespace),
        oneShotGetTokenError:    m.k8CTOneShotError,
	}
}

// Mock the K8s service account client
type mockK8sV1SA struct {
	k8sv1.ServiceAccountInterface
	oneShotGetTokenError bool
}

func (ma *mockK8sV1SA) CreateToken(
	ctx context.Context,
	serviceAccountName string,
	tokenRequest *authv1.TokenRequest,
	opts metav1.CreateOptions,
) (*authv1.TokenRequest, error) {

	if ma.oneShotGetTokenError {
		ma.oneShotGetTokenError = false // Reset so other tests don't fail
		return nil, fmt.Errorf("Fake create token error")
	}

	return &authv1.TokenRequest{
		Status: authv1.TokenRequestStatus{
			Token: "FAKETOKEN",
		},
	}, nil
}
