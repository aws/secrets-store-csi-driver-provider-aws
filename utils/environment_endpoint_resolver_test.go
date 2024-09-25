package utils

import (
	"os"
	"testing"

	"github.com/aws/aws-sdk-go/aws/endpoints"
	"github.com/stretchr/testify/assert"
)

func TestEnvironmentEndpointResolver_EndpointFor_Disabled(t *testing.T) {
	err := os.Setenv("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "true")
	assert.NoError(t, err)

	err = os.Setenv("AWS_ENDPOINT_URL", "https://127.0.0.1:443") // should be ignored
	assert.NoError(t, err)

	endpoint, err := EnvironmentEndpointResolver().
		EndpointFor("sts", "us-west-1", endpoints.STSRegionalEndpointOption)
	assert.NoError(t, err)

	assert.Equal(t, "aws", endpoint.PartitionID)
	assert.Equal(t, "v4", endpoint.SigningMethod)
	assert.Equal(t, "sts", endpoint.SigningName)
	assert.Equal(t, true, endpoint.SigningNameDerived)
	assert.Equal(t, "us-west-1", endpoint.SigningRegion)
	assert.Equal(t, "https://sts.us-west-1.amazonaws.com", endpoint.URL)
}

func TestEnvironmentEndpointResolver_EndpointFor_Default(t *testing.T) {
	err := os.Unsetenv("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS")
	assert.NoError(t, err)

	err = os.Unsetenv("AWS_ENDPOINT_URL_STS")
	assert.NoError(t, err)

	err = os.Setenv("AWS_ENDPOINT_URL", "https://127.0.0.1:443")
	assert.NoError(t, err)

	endpoint, err := EnvironmentEndpointResolver().
		EndpointFor("sts", "us-west-1", endpoints.STSRegionalEndpointOption)
	assert.NoError(t, err)

	assert.Equal(t, "", endpoint.PartitionID)
	assert.Equal(t, "", endpoint.SigningMethod)
	assert.Equal(t, "", endpoint.SigningName)
	assert.Equal(t, false, endpoint.SigningNameDerived)
	assert.Equal(t, "", endpoint.SigningRegion)
	assert.Equal(t, "https://127.0.0.1:443", endpoint.URL)
}

func TestEnvironmentEndpointResolver_EndpointFor_ServiceSpecific(t *testing.T) {
	err := os.Setenv("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "false")
	assert.NoError(t, err)

	err = os.Setenv("AWS_ENDPOINT_URL", "https://127.0.0.1:443/default")
	assert.NoError(t, err)

	err = os.Setenv("AWS_ENDPOINT_URL_STS", "https://127.0.0.1:443/service-specific")
	assert.NoError(t, err)

	endpoint, err := EnvironmentEndpointResolver().
		EndpointFor("sts", "us-west-1", endpoints.STSRegionalEndpointOption)
	assert.NoError(t, err)

	assert.Equal(t, "", endpoint.PartitionID)
	assert.Equal(t, "", endpoint.SigningMethod)
	assert.Equal(t, "", endpoint.SigningName)
	assert.Equal(t, false, endpoint.SigningNameDerived)
	assert.Equal(t, "", endpoint.SigningRegion)
	assert.Equal(t, "https://127.0.0.1:443/service-specific", endpoint.URL)
}

func TestEnvironmentEndpointResolver_EndpointFor_ServiceSpecificCustom(t *testing.T) {
	err := os.Setenv("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "false")
	assert.NoError(t, err)

	err = os.Setenv("AWS_ENDPOINT_URL", "https://127.0.0.1:443/default")
	assert.NoError(t, err)

	err = os.Setenv("AWS_ENDPOINT_URL_SECRETS_MANAGER", "https://127.0.0.1:443/service-specific")
	assert.NoError(t, err)

	endpoint, err := EnvironmentEndpointResolver().
		EndpointFor("secretsmanager", "us-west-1", endpoints.STSRegionalEndpointOption)
	assert.NoError(t, err)

	assert.Equal(t, "", endpoint.PartitionID)
	assert.Equal(t, "", endpoint.SigningMethod)
	assert.Equal(t, "", endpoint.SigningName)
	assert.Equal(t, false, endpoint.SigningNameDerived)
	assert.Equal(t, "", endpoint.SigningRegion)
	assert.Equal(t, "https://127.0.0.1:443/service-specific", endpoint.URL)
}
