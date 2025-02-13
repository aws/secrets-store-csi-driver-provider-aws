package utils

import (
	"errors"

	"github.com/aws/smithy-go"
)

// Helper method to check if the request is fatal/4XX status
func IsFatalError(errMsg error) bool {
	var ae smithy.APIError
	if errors.As(errMsg, &ae) {
		// check if client side error occurred
		return ae.ErrorFault() == smithy.FaultClient
	}
	if errors.Unwrap(errMsg) != nil {
		return IsFatalError(errors.Unwrap(errMsg))
	}
	return false
}
