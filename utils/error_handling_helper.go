package utils

import (
	"errors"

	"github.com/aws/aws-sdk-go/aws/awserr"
)

//Helper method to check if the request is fatal/4XX status
func IsFatalError(errMsg error) bool {

	if reqErr, ok := errMsg.(awserr.RequestFailure); ok {
		// check if client side error occurred
		if reqErr.StatusCode() >= 400 && reqErr.StatusCode() < 500 {
			return true
		}
	}
	if reqErr, ok := errMsg.(awserr.Error); ok {
		if reqErr.OrigErr() != nil {
			return IsFatalError(reqErr.OrigErr())
		}
	}
	if errors.Unwrap(errMsg) != nil {
		return IsFatalError(errors.Unwrap(errMsg))
	}
	return false
}
