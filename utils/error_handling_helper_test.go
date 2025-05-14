package utils

import (
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	secretsmanagertypes "github.com/aws/aws-sdk-go-v2/service/secretsmanager/types"
	ssmtypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"
)

func TestIsFatalError(t *testing.T) {
	cases := []struct {
		name    string
		err     error
		isFatal bool
	}{
		{
			name: "asm ResourceNotFoundException",
			err: &secretsmanagertypes.ResourceNotFoundException{
				Message:           aws.String("Secret not found"),
				ErrorCodeOverride: aws.String("400"),
			},
			isFatal: true,
		},
		{
			name: "ssm InternalServerError",
			err: &ssmtypes.InternalServerError{
				Message:           aws.String("Internal server error occurred"),
				ErrorCodeOverride: aws.String("500"),
			},
			isFatal: false,
		},
		{
			name: "ssm InvalidParameterException",
			err: &ssmtypes.InvalidParameters{
				Message:           aws.String("Invalid parameter value"),
				ErrorCodeOverride: aws.String("400"),
			},
			isFatal: true,
		},
	}

	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			if IsFatalError(c.err) != c.isFatal {
				t.Errorf("Expected IsFatalError(%v) to be %v", c.err, c.isFatal)
			}
		})
	}
}