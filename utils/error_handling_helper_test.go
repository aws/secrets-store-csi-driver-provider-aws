package utils

import (
	"testing"

	"github.com/aws/aws-sdk-go/aws/awserr"
	"github.com/stretchr/testify/assert"
)

type awsError awserr.Error

type WrapAwsError struct {
	awsError
	code string

	message string

	err error
}

func (w WrapAwsError) Error() string {
	return awserr.SprintError(w.code, w.message, "", w.OrigErr())
}

func (w WrapAwsError) OrigErr() error {
	return w.err
}

func TestIsFatalError_CannotAssumeRoleWithWebIdentity_isFatal(t *testing.T) {
	innerErr := WrapAwsError{code: "AccessDenied", message: "Not authorized to perform sts:AssumeRoleWithWebIdentity", err: nil}
	awsRequestError := awserr.NewRequestFailure(innerErr, 403, "someId")
	returnedErr := WrapAwsError{code: "WebIdentityErr", message: "failed to retrieve credentials", err: awsRequestError}

	fatalError := IsFatalError(returnedErr)

	assert.Equal(t, true, fatalError)
}

func TestIsFatalError_WrapperWithoutOriginError_nonFatal(t *testing.T) {
	returnedErr := WrapAwsError{code: "WebIdentityErr", message: "failed to retrieve credentials", err: nil}

	fatalError := IsFatalError(returnedErr)

	assert.Equal(t, false, fatalError)
}
