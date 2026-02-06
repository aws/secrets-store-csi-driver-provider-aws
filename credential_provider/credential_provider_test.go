package credential_provider

import (
	"context"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/aws-sdk-go-v2/service/sts/types"
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
