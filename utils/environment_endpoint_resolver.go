package utils

import (
	"os"
	"strings"

	"github.com/aws/aws-sdk-go/aws/endpoints"
)

const (
	envVarDisable    = "AWS_IGNORE_CONFIGURED_ENDPOINT_URLS"
	envVarUrlDefault = "AWS_ENDPOINT_URL"
	envVarUrlPrefix  = "AWS_ENDPOINT_URL_"
)

// non-standard endpoint service name to environment variable suffix mappings
var serviceToEnv = map[string]string{
	"secretsmanager": "SECRETS_MANAGER",
}

var envResolver = endpoints.ResolverFunc(envResolve)

// EnvironmentEndpointResolver uses environment variables to locate endpoints.
//
// Uses environment variables compatible with the service specific endpoints
// feature to locate service endpoints:
//
//   - AWS_ENDPOINT_URL - default endpoint
//   - AWS_ENDPOINT_URL_<SERVICE> - service specific endpoint
//   - AWS_IGNORE_CONFIGURED_ENDPOINT_URLS - "true" to ignore configured
//
// When AWS_IGNORE_CONFIGURED_ENDPOINT_URLS is "true" all environment
// variables are ignored.
//
// When an endpoint is not configured via environment the default resolver
// is used.
func EnvironmentEndpointResolver() endpoints.Resolver {
	return envResolver
}

// envResolveEnabled should environment endpoints be used
func envResolveEnabled() bool {
	return "true" != os.Getenv(envVarDisable)
}

// serviceUrlEnvVar look up the custom mapping or use standard transform
func serviceUrlEnvVar(service string) string {
	envVarSuffix, ok := serviceToEnv[service]
	if !ok {
		envVarSuffix = strings.ReplaceAll(strings.ToUpper(service), "-", "_")
	}
	return envVarUrlPrefix + envVarSuffix
}

// urlFromEnvironment lookup url from service specific or default environment variable
func urlFromEnvironment(service string) string {
	url := os.Getenv(serviceUrlEnvVar(service))
	if url == "" {
		url = os.Getenv(envVarUrlDefault)
	}
	return url
}

// envResolve lookup service endpoint via environment variables if enabled
func envResolve(service string, region string, opts ...func(*endpoints.Options)) (endpoints.ResolvedEndpoint, error) {
	if envResolveEnabled() {
		if url := urlFromEnvironment(service); url != "" {
			return endpoints.ResolvedEndpoint{
				URL: url,
			}, nil
		}
	}
	return endpoints.DefaultResolver().EndpointFor(service, region, opts...)
}
