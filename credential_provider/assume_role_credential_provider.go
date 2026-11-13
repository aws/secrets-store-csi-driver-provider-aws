package credential_provider

import (
	"context"
	"errors"
	"fmt"
	"regexp"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/aws/retry"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	"github.com/aws/smithy-go"
)

// STS limits a RoleSessionName to 2 to 64 characters.
const (
	minRoleSessionNameLen = 2
	maxRoleSessionNameLen = 64
)

// defaultRoleSessionName is used when the mount request carries neither a
// namespace nor a service account name, so the derived name would be too
// short for STS.
const defaultRoleSessionName = "secrets-store-csi-driver-provider-aws"

// roleArnPattern matches arn:<partition>:iam::<12 digit account>:role/<path/><name>.
// Role names allow [\w+=,.@-]; paths add '/'. Anything that passes here but is
// not a real role is rejected by STS, which fails the mount.
var roleArnPattern = regexp.MustCompile(`^arn:[\w-]+:iam::\d{12}:role/[\w+=,.@/-]+$`)

// AssumeRoleConfig is a validated STS AssumeRole configuration for one mount.
//
// The session uses the SDK default duration of 15 minutes; the credentials
// are discarded when the mount finishes. No external ID is sent: the
// SecretProviderClass author chooses the role ARN, so an external ID they
// also chose would protect nothing.
type AssumeRoleConfig struct {
	RoleArn         string
	RoleSessionName string
}

// ParseAssumeRoleConfig validates the assumeRoleArn SecretProviderClass
// parameter. It returns nil when the parameter is absent and an error when it
// is malformed; the caller must not fall back to the base credentials.
func ParseAssumeRoleConfig(roleArn, nameSpace, svcAcct string) (*AssumeRoleConfig, error) {
	if roleArn == "" {
		return nil, nil
	}

	if !roleArnPattern.MatchString(roleArn) {
		return nil, fmt.Errorf("invalid assumeRoleArn %q: must be an IAM role ARN (arn:<partition>:iam::<account>:role/<name>)", roleArn)
	}

	return &AssumeRoleConfig{
		RoleArn:         roleArn,
		RoleSessionName: RoleSessionName(nameSpace, svcAcct),
	}, nil
}

// RoleSessionName returns <namespace>@<serviceAccount>, which is what the
// target account sees in CloudTrail. The SecretProviderClass cannot override
// it. "@" cannot appear in Kubernetes names, so the two parts are unambiguous.
// Names over the STS limit of 64 characters are cut at 64.
//
// Both values come from the kubelet via the driver (podInfoOnMount), which the
// chart sets, so with a working driver neither is empty. If both are missing
// the name would be the single character "@", which STS rejects, so a fixed
// default is used instead. Kubernetes names only contain characters STS
// accepts, so nothing is sanitized here.
func RoleSessionName(nameSpace, svcAcct string) string {
	name := nameSpace + "@" + svcAcct
	if len(name) < minRoleSessionNameLen {
		return defaultRoleSessionName
	}
	if len(name) > maxRoleSessionNameLen {
		name = name[:maxRoleSessionNameLen]
	}
	return name
}

// AssumeRoleCredentialProvider wraps a base ConfigProvider (IRSA or Pod
// Identity) and replaces the credentials in its config with an STS AssumeRole
// provider, so every Secrets Manager and Parameter Store call for the mount
// runs as the assumed role.
type AssumeRoleCredentialProvider struct {
	base   ConfigProvider
	config AssumeRoleConfig

	// newSTSClient builds the STS client from the base config. Overridable in tests.
	newSTSClient func(aws.Config) stscreds.AssumeRoleAPIClient
}

// NewAssumeRoleCredentialProvider returns a provider whose GetAWSConfig
// yields credentials for config.RoleArn. config must come from
// ParseAssumeRoleConfig.
func NewAssumeRoleCredentialProvider(base ConfigProvider, config AssumeRoleConfig) ConfigProvider {
	return &AssumeRoleCredentialProvider{
		base:   base,
		config: config,
		newSTSClient: func(cfg aws.Config) stscreds.AssumeRoleAPIClient {
			return sts.NewFromConfig(cfg)
		},
	}
}

func (p *AssumeRoleCredentialProvider) GetAWSConfig(ctx context.Context) (aws.Config, error) {
	cfg, err := p.base.GetAWSConfig(ctx)
	if err != nil {
		return aws.Config{}, err
	}

	// The STS client is built from the base config, so it signs with the base
	// credentials and uses the base region's STS endpoint, app ID and retryer.
	//
	// Retries happen at two levels on purpose. This client retries a throttled
	// or failed AssumeRole up to 3 times, and the Secrets Manager or SSM call
	// that triggered the credential fetch retries up to 3 times as well, so a
	// transient STS problem can cost about 9 AssumeRole calls per region before
	// the failover region gets its turn. A permanent rejection costs one call.
	stsClient := &fatalOnClientErrorSTSClient{client: p.newSTSClient(cfg)}
	provider := stscreds.NewAssumeRoleProvider(stsClient, p.config.RoleArn, func(o *stscreds.AssumeRoleOptions) {
		o.RoleSessionName = p.config.RoleSessionName
	})

	cfg.Credentials = aws.NewCredentialsCache(provider)
	return cfg, nil
}

// fatalOnClientErrorSTSClient marks permanent AssumeRole rejections as client
// faults, which the provider treats as fatal: the mount fails at once with the
// STS error in the pod event, and the failover region is skipped because trust
// and permission errors would repeat there.
//
// The STS SDK only types four AssumeRole errors; AccessDenied, the usual
// trust-policy mistake, arrives as a generic error with no fault, which the
// provider would otherwise log as a warning and retry in the failover region.
// Any 4xx the SDK would not retry is re-classified here. Errors the SDK does
// retry (throttling, request timeouts, 5xx, connection errors) pass through
// unchanged so the failover region gets its own attempt.
//
// The base credentials are resolved inside the AssumeRole call, so with an
// IRSA base a permanent AssumeRoleWithWebIdentity rejection is classified the
// same way. Mounts without assumeRoleArn are not affected.
type fatalOnClientErrorSTSClient struct {
	client stscreds.AssumeRoleAPIClient
}

func (c *fatalOnClientErrorSTSClient) AssumeRole(ctx context.Context, in *sts.AssumeRoleInput, optFns ...func(*sts.Options)) (*sts.AssumeRoleOutput, error) {
	out, err := c.client.AssumeRole(ctx, in, optFns...)
	if err != nil && isPermanentClientError(err) {
		return nil, &AssumeRoleError{err: err}
	}
	return out, err
}

// sdkRetryables is the SDK's own view of what is worth sending again:
// throttle codes, request timeouts, 5xx responses and connection errors.
var sdkRetryables = retry.IsErrorRetryables(retry.DefaultRetryables)

// isPermanentClientError reports whether err is an HTTP 4xx API error that the
// SDK would not retry.
func isPermanentClientError(err error) bool {
	var ae smithy.APIError
	if !errors.As(err, &ae) {
		return false // connection error, timeout, context cancellation
	}
	// Checked before the fault: a retryable error stays retryable however the
	// SDK typed it, and the failover region has its own STS endpoint and quota.
	if sdkRetryables.IsErrorRetryable(err) == aws.TrueTernary {
		return false
	}
	if ae.ErrorFault() == smithy.FaultClient {
		return true // already typed as a client fault
	}
	var httpErr interface{ HTTPStatusCode() int }
	if !errors.As(err, &httpErr) {
		return false
	}
	code := httpErr.HTTPStatusCode()
	return code >= 400 && code < 500
}

// AssumeRoleError reports a permanent STS AssumeRole rejection as a client
// fault while keeping the wrapped error's code, message and text, so the STS
// detail reaches the mount error and the pod event.
type AssumeRoleError struct {
	err error
}

func (e *AssumeRoleError) Error() string { return e.err.Error() }
func (e *AssumeRoleError) Unwrap() error { return e.err }

func (e *AssumeRoleError) ErrorCode() string {
	var ae smithy.APIError
	if errors.As(e.err, &ae) {
		return ae.ErrorCode()
	}
	return "AssumeRoleError"
}

func (e *AssumeRoleError) ErrorMessage() string {
	var ae smithy.APIError
	if errors.As(e.err, &ae) {
		return ae.ErrorMessage()
	}
	return e.err.Error()
}

func (e *AssumeRoleError) ErrorFault() smithy.ErrorFault { return smithy.FaultClient }
