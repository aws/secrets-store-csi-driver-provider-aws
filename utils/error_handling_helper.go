package utils

import (
	"errors"

	"github.com/aws/smithy-go"
)

// JSONProcessingError indicates a failure to parse or extract JSON using jmesPath.
// These errors are not region-specific and should fail fast instead of retrying other regions.
type JSONProcessingError struct {
	Message string
}

func (e *JSONProcessingError) Error() string { return e.Message }

// Helper method to check if the request is fatal/4XX status
func IsFatalError(errMsg error) bool {

	var jpe *JSONProcessingError
	if errors.As(errMsg, &jpe) {
		return true
	}

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
