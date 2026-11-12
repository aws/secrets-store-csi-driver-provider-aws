package credential_provider

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	awshttp "github.com/aws/aws-sdk-go-v2/aws/transport/http"
	"github.com/aws/aws-sdk-go-v2/credentials"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/aws/aws-sdk-go-v2/service/sts"
	ststypes "github.com/aws/aws-sdk-go-v2/service/sts/types"
	"github.com/aws/smithy-go"
	smithyhttp "github.com/aws/smithy-go/transport/http"

	"github.com/aws/secrets-store-csi-driver-provider-aws/utils"
)

const testRoleArn = "arn:aws:iam::123456789012:role/TargetRole"

func TestParseAssumeRoleConfig(t *testing.T) {
	tests := []struct {
		name      string
		roleArn   string
		expectNil bool
		expectErr string
	}{
		{name: "not requested", expectNil: true},
		{name: "arn only", roleArn: testRoleArn},
		{name: "arn with path", roleArn: "arn:aws:iam::123456789012:role/path/to/Role_Name+=,.@-"},
		{name: "arn in china partition", roleArn: "arn:aws-cn:iam::123456789012:role/TargetRole"},
		{name: "arn in govcloud partition", roleArn: "arn:aws-us-gov:iam::123456789012:role/TargetRole"},

		// A malformed ARN must fail, never fall through to the base credentials.
		{name: "arn is a user", roleArn: "arn:aws:iam::123456789012:user/Bob", expectErr: "invalid assumeRoleArn"},
		{name: "arn is not iam", roleArn: "arn:aws:sts::123456789012:assumed-role/X/Y", expectErr: "invalid assumeRoleArn"},
		{name: "arn short account", roleArn: "arn:aws:iam::12345:role/TargetRole", expectErr: "invalid assumeRoleArn"},
		{name: "arn with region", roleArn: "arn:aws:iam:us-east-1:123456789012:role/TargetRole", expectErr: "invalid assumeRoleArn"},
		{name: "arn empty role name", roleArn: "arn:aws:iam::123456789012:role/", expectErr: "invalid assumeRoleArn"},
		{name: "arn bad chars", roleArn: "arn:aws:iam::123456789012:role/Target Role", expectErr: "invalid assumeRoleArn"},
		{name: "arn surrounding whitespace", roleArn: " " + testRoleArn, expectErr: "invalid assumeRoleArn"},
		{name: "arn newline injection", roleArn: testRoleArn + "\nfoo", expectErr: "invalid assumeRoleArn"},
		{name: "arn garbage", roleArn: "TargetRole", expectErr: "invalid assumeRoleArn"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			cfg, err := ParseAssumeRoleConfig(tt.roleArn, "ns", "sa")

			if tt.expectErr != "" {
				if err == nil {
					t.Fatalf("expected error containing %q, got nil (cfg=%+v)", tt.expectErr, cfg)
				}
				if !strings.Contains(err.Error(), tt.expectErr) {
					t.Fatalf("expected error containing %q, got %q", tt.expectErr, err.Error())
				}
				if cfg != nil {
					t.Fatalf("expected nil config on error, got %+v", cfg)
				}
				return
			}
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}
			if tt.expectNil {
				if cfg != nil {
					t.Fatalf("expected nil config, got %+v", cfg)
				}
				return
			}
			if cfg == nil {
				t.Fatal("expected config, got nil")
			}
			if cfg.RoleArn != tt.roleArn {
				t.Errorf("RoleArn = %q, want %q", cfg.RoleArn, tt.roleArn)
			}
			if cfg.RoleSessionName != "ns@sa" {
				t.Errorf("RoleSessionName = %q, want %q", cfg.RoleSessionName, "ns@sa")
			}
		})
	}
}

func TestRoleSessionName(t *testing.T) {
	longNS := strings.Repeat("n", 63) // longest namespace Kubernetes allows

	tests := []struct {
		name      string
		nameSpace string
		svcAcct   string
		want      string
	}{
		{name: "simple", nameSpace: "default", svcAcct: "nginx-sa", want: "default@nginx-sa"},
		{name: "dns names pass through", nameSpace: "team.a", svcAcct: "svc-acct.v2", want: "team.a@svc-acct.v2"},
		{name: "exactly 64 is not truncated", nameSpace: strings.Repeat("n", 40), svcAcct: strings.Repeat("s", 23), want: strings.Repeat("n", 40) + "@" + strings.Repeat("s", 23)},
		{name: "longer than 64 is cut at 64", nameSpace: strings.Repeat("n", 40), svcAcct: strings.Repeat("s", 30), want: strings.Repeat("n", 40) + "@" + strings.Repeat("s", 23)},
		{name: "longest namespace leaves only the separator", nameSpace: longNS, svcAcct: "payments-api", want: longNS + "@"},

		// Pod info is always present with a working driver; a mount without it
		// must still produce a name STS accepts.
		{name: "missing namespace keeps the service account", nameSpace: "", svcAcct: "sa", want: "@sa"},
		{name: "missing service account keeps the namespace", nameSpace: "ns", svcAcct: "", want: "ns@"},
		{name: "missing both falls back to the default", nameSpace: "", svcAcct: "", want: defaultRoleSessionName},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := RoleSessionName(tt.nameSpace, tt.svcAcct)
			if got != tt.want {
				t.Fatalf("RoleSessionName(%q, %q) = %q, want %q", tt.nameSpace, tt.svcAcct, got, tt.want)
			}
			assertValidSessionName(t, got)
		})
	}

	// With "-" as the separator, "team-a"+"app" and "team"+"a-app" would collide.
	t.Run("separator is unambiguous", func(t *testing.T) {
		a, b := RoleSessionName("team-a", "app"), RoleSessionName("team", "a-app")
		if a == b {
			t.Fatalf("different workloads produced the same session name %q", a)
		}
	})
}

// STS accepts a RoleSessionName of 2 to 64 characters from [\w+=,.@-].
var stsSessionNamePattern = regexp.MustCompile(`^[\w+=,.@-]{2,64}$`)

func assertValidSessionName(t *testing.T, name string) {
	t.Helper()
	if !stsSessionNamePattern.MatchString(name) {
		t.Fatalf("session name %q would be rejected by STS", name)
	}
}

// staticConfigProvider is a base ConfigProvider returning fixed credentials.
type staticConfigProvider struct {
	cfg aws.Config
	err error
}

func (p *staticConfigProvider) GetAWSConfig(context.Context) (aws.Config, error) {
	return p.cfg, p.err
}

// mockSTSClient records the AssumeRole request and returns fixed credentials.
type mockSTSClient struct {
	input *sts.AssumeRoleInput
	err   error

	// cfg is the aws.Config the provider built the STS client from.
	cfg aws.Config
}

func (m *mockSTSClient) AssumeRole(ctx context.Context, in *sts.AssumeRoleInput, optFns ...func(*sts.Options)) (*sts.AssumeRoleOutput, error) {
	m.input = in
	if m.err != nil {
		return nil, m.err
	}
	return &sts.AssumeRoleOutput{
		Credentials: &ststypes.Credentials{
			AccessKeyId:     aws.String("ASSUMED_KEY"),
			SecretAccessKey: aws.String("ASSUMED_SECRET"),
			SessionToken:    aws.String("ASSUMED_TOKEN"),
			Expiration:      aws.Time(time.Now().Add(time.Hour)),
		},
	}, nil
}

func newTestAssumeRoleProvider(base ConfigProvider, cfg AssumeRoleConfig, stsClient *mockSTSClient) *AssumeRoleCredentialProvider {
	p := NewAssumeRoleCredentialProvider(base, cfg).(*AssumeRoleCredentialProvider)
	p.newSTSClient = func(cfg aws.Config) stscreds.AssumeRoleAPIClient {
		stsClient.cfg = cfg
		return stsClient
	}
	return p
}

func baseConfig() aws.Config {
	return aws.Config{
		Region:      "us-west-2",
		Credentials: credentials.NewStaticCredentialsProvider("BASE_KEY", "BASE_SECRET", "BASE_TOKEN"),
	}
}

func TestAssumeRoleCredentialProvider_GetAWSConfig(t *testing.T) {
	stsClient := &mockSTSClient{}
	p := newTestAssumeRoleProvider(&staticConfigProvider{cfg: baseConfig()}, AssumeRoleConfig{RoleArn: testRoleArn, RoleSessionName: "ns@sa"}, stsClient)

	cfg, err := p.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if cfg.Region != "us-west-2" {
		t.Errorf("Region = %q, want base region preserved", cfg.Region)
	}
	if stsClient.input != nil {
		t.Fatal("AssumeRole must be lazy; it was called during GetAWSConfig")
	}

	// The STS client must come from the pod's base config: base region, and
	// credentials that resolve to the base identity, not the node's.
	if stsClient.cfg.Region != "us-west-2" {
		t.Errorf("STS client region = %q, want the base region", stsClient.cfg.Region)
	}
	if stsClient.cfg.Credentials == nil {
		t.Fatal("STS client was built without the base credentials")
	}
	baseCreds, err := stsClient.cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("unexpected error resolving the STS client's credentials: %v", err)
	}
	if baseCreds.AccessKeyID != "BASE_KEY" {
		t.Errorf("STS client signs with %q, want the base credentials BASE_KEY", baseCreds.AccessKeyID)
	}

	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err != nil {
		t.Fatalf("unexpected retrieve error: %v", err)
	}
	if creds.AccessKeyID != "ASSUMED_KEY" || creds.SecretAccessKey != "ASSUMED_SECRET" || creds.SessionToken != "ASSUMED_TOKEN" {
		t.Fatalf("expected assumed-role credentials, got %+v", creds)
	}

	in := stsClient.input
	if in == nil {
		t.Fatal("AssumeRole was not called")
	}
	if aws.ToString(in.RoleArn) != testRoleArn {
		t.Errorf("RoleArn = %q, want %q", aws.ToString(in.RoleArn), testRoleArn)
	}
	if aws.ToString(in.RoleSessionName) != "ns@sa" {
		t.Errorf("RoleSessionName = %q, want %q", aws.ToString(in.RoleSessionName), "ns@sa")
	}
	// Session duration stays at the SDK default and no external ID is sent.
	if aws.ToInt32(in.DurationSeconds) != 900 {
		t.Errorf("DurationSeconds = %d, want the SDK default of 900", aws.ToInt32(in.DurationSeconds))
	}
	if in.ExternalId != nil {
		t.Errorf("ExternalId = %q, want none", aws.ToString(in.ExternalId))
	}
	if in.Policy != nil || len(in.PolicyArns) != 0 || len(in.Tags) != 0 || in.SourceIdentity != nil {
		t.Errorf("unexpected extra AssumeRole fields set: %+v", in)
	}

	// Second retrieve must hit the cache, not STS.
	stsClient.input = nil
	if _, err := cfg.Credentials.Retrieve(context.Background()); err != nil {
		t.Fatalf("unexpected retrieve error: %v", err)
	}
	if stsClient.input != nil {
		t.Error("expected cached credentials on second retrieve, but AssumeRole was called again")
	}
}

func TestAssumeRoleCredentialProvider_BaseError(t *testing.T) {
	baseErr := errors.New("base provider failed")
	stsClient := &mockSTSClient{}
	p := newTestAssumeRoleProvider(&staticConfigProvider{err: baseErr}, AssumeRoleConfig{RoleArn: testRoleArn, RoleSessionName: "ns@sa"}, stsClient)

	if _, err := p.GetAWSConfig(context.Background()); !errors.Is(err, baseErr) {
		t.Fatalf("expected base error to propagate, got %v", err)
	}
	if stsClient.input != nil {
		t.Fatal("AssumeRole must not be called when the base provider fails")
	}
}

func TestAssumeRoleCredentialProvider_STSError(t *testing.T) {
	stsClient := &mockSTSClient{err: stsAPIError(403, "AccessDenied", accessDeniedMessage)}
	p := newTestAssumeRoleProvider(&staticConfigProvider{cfg: baseConfig()}, AssumeRoleConfig{RoleArn: testRoleArn, RoleSessionName: "ns@sa"}, stsClient)

	cfg, err := p.GetAWSConfig(context.Background())
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	creds, err := cfg.Credentials.Retrieve(context.Background())
	if err == nil {
		t.Fatal("expected error from STS to surface on Retrieve")
	}
	if !strings.Contains(err.Error(), "AccessDenied") {
		t.Errorf("expected STS error to be wrapped, got %v", err)
	}
	var are *AssumeRoleError
	if !errors.As(err, &are) {
		t.Errorf("expected a permanent rejection to be wrapped in AssumeRoleError, got %T: %v", err, err)
	}
	// Nothing falls back to the base credentials: the error carries no keys,
	// and the failure came from an attempted AssumeRole, not from skipping it.
	if creds.HasKeys() {
		t.Fatalf("credentials returned alongside the error: %+v", creds)
	}
	if stsClient.input == nil {
		t.Fatal("AssumeRole was not called")
	}
}

func TestNewAssumeRoleCredentialProvider_UsesSTSClient(t *testing.T) {
	p := NewAssumeRoleCredentialProvider(&staticConfigProvider{cfg: baseConfig()}, AssumeRoleConfig{RoleArn: testRoleArn}).(*AssumeRoleCredentialProvider)
	if _, ok := p.newSTSClient(baseConfig()).(*sts.Client); !ok {
		t.Fatal("expected default STS client factory to return *sts.Client")
	}
}

// stsAPIError builds the error chain the real STS client returns for an
// untyped API error (OperationError wrapping ResponseError wrapping
// GenericAPIError). GenericAPIError.Fault is unset, so it is not a client fault.
func stsAPIError(status int, code, message string) error {
	return stsOperationError("AssumeRole", status, code, message)
}

// stsOperationError is stsAPIError for a named STS operation.
func stsOperationError(operation string, status int, code, message string) error {
	return &smithy.OperationError{
		ServiceID:     "STS",
		OperationName: operation,
		Err: &awshttp.ResponseError{
			ResponseError: &smithyhttp.ResponseError{
				Response: &smithyhttp.Response{Response: &http.Response{StatusCode: status}},
				Err:      &smithy.GenericAPIError{Code: code, Message: message},
			},
			RequestID: "req-1",
		},
	}
}

// stsTypedError builds the chain for one of the four typed AssumeRole errors,
// which the SDK already marks as a client fault.
func stsTypedError() error {
	return &smithy.OperationError{
		ServiceID:     "STS",
		OperationName: "AssumeRole",
		Err: &awshttp.ResponseError{
			ResponseError: &smithyhttp.ResponseError{
				Response: &smithyhttp.Response{Response: &http.Response{StatusCode: 403}},
				Err:      &ststypes.RegionDisabledException{Message: aws.String("STS is not activated in this region")},
			},
		},
	}
}

const accessDeniedMessage = "User: arn:aws:sts::111111111111:assumed-role/BaseRole/ns@sa is not authorized to perform: sts:AssumeRole on resource: arn:aws:iam::123456789012:role/TargetRole"

func TestIsPermanentClientError(t *testing.T) {
	tests := []struct {
		name string
		err  error
		want bool
	}{
		// Permanent rejections of this mount: fail now, skip the failover region.
		{name: "access denied", err: stsAPIError(403, "AccessDenied", accessDeniedMessage), want: true},
		{name: "invalid client token", err: stsAPIError(403, "InvalidClientTokenId", "The security token included in the request is invalid"), want: true},
		{name: "validation error", err: stsAPIError(400, "ValidationError", "1 validation error detected"), want: true},
		{name: "typed client fault", err: stsTypedError(), want: true},

		// Transient: the SDK retries these, then the failover region gets its own try.
		{name: "throttling", err: stsAPIError(400, "Throttling", "Rate exceeded"), want: false},
		{name: "throttling exception", err: stsAPIError(400, "ThrottlingException", "Rate exceeded"), want: false},
		// The SDK retries request timeouts too, so they are not permanent either.
		{name: "request timeout", err: stsAPIError(408, "RequestTimeout", "Your socket connection to the server was not read from or written to within the timeout period"), want: false},
		{name: "request timeout exception", err: stsAPIError(408, "RequestTimeoutException", "timed out"), want: false},
		// A throttling code must stay retryable even if the SDK ever types it as a client fault.
		{name: "throttling typed as client fault", err: &smithy.OperationError{
			ServiceID: "STS", OperationName: "AssumeRole",
			Err: &awshttp.ResponseError{
				ResponseError: &smithyhttp.ResponseError{
					Response: &smithyhttp.Response{Response: &http.Response{StatusCode: 400}},
					Err:      &smithy.GenericAPIError{Code: "Throttling", Message: "Rate exceeded", Fault: smithy.FaultClient},
				},
			},
		}, want: false},
		{name: "internal failure", err: stsAPIError(500, "InternalFailure", "An internal error occurred"), want: false},
		{name: "service unavailable", err: stsAPIError(503, "ServiceUnavailable", "Service is unavailable"), want: false},
		{name: "connection error", err: &smithy.OperationError{ServiceID: "STS", OperationName: "AssumeRole", Err: errors.New("dial tcp: i/o timeout")}, want: false},
		{name: "context canceled", err: context.Canceled, want: false},
		{name: "api error without http response", err: &smithy.GenericAPIError{Code: "AccessDenied", Message: "no response in chain"}, want: false},
		{name: "nil", err: nil, want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isPermanentClientError(tt.err); got != tt.want {
				t.Fatalf("isPermanentClientError(%v) = %v, want %v", tt.err, got, tt.want)
			}
		})
	}
}

// noNetwork fails the test if a request leaves the process. Credentials are
// resolved before the request is sent, so a credential failure never needs one.
type noNetwork struct{ t *testing.T }

func (n noNetwork) Do(*http.Request) (*http.Response, error) {
	n.t.Fatal("unexpected network call")
	return nil, errors.New("unreachable")
}

// TestAssumeRoleErrorClassification runs a real Secrets Manager client over the
// assume-role credentials and checks whether each STS failure is classified as
// fatal (mount fails at once) or not (provider tries the failover region).
func TestAssumeRoleErrorClassification(t *testing.T) {
	tests := []struct {
		name      string
		stsErr    error
		wantFatal bool
		wantText  []string
	}{
		{
			name:      "access denied is fatal and keeps the STS detail",
			stsErr:    stsAPIError(403, "AccessDenied", accessDeniedMessage),
			wantFatal: true,
			wantText:  []string{"operation error STS: AssumeRole", "AccessDenied", accessDeniedMessage},
		},
		{
			name:      "typed client error is fatal",
			stsErr:    stsTypedError(),
			wantFatal: true,
			wantText:  []string{"RegionDisabledException"},
		},
		{
			// The base credentials are resolved inside the AssumeRole call, so an
			// IRSA first-hop denial surfaces through it and is fatal as well.
			name: "first hop access denied is fatal",
			stsErr: &smithy.OperationError{
				ServiceID:     "STS",
				OperationName: "AssumeRole",
				Err: fmt.Errorf("get identity: get credentials: failed to refresh cached credentials, %w",
					stsOperationError("AssumeRoleWithWebIdentity", 403, "AccessDenied", "Not authorized to perform sts:AssumeRoleWithWebIdentity")),
			},
			wantFatal: true,
			wantText:  []string{"operation error STS: AssumeRoleWithWebIdentity", "AccessDenied"},
		},
		{
			name:      "throttling is not fatal",
			stsErr:    stsAPIError(400, "Throttling", "Rate exceeded"),
			wantFatal: false,
			wantText:  []string{"Throttling"},
		},
		{
			name:      "request timeout is not fatal",
			stsErr:    stsAPIError(408, "RequestTimeout", "timed out"),
			wantFatal: false,
			wantText:  []string{"RequestTimeout"},
		},
		{
			name:      "server error is not fatal",
			stsErr:    stsAPIError(500, "InternalFailure", "An internal error occurred"),
			wantFatal: false,
			wantText:  []string{"InternalFailure"},
		},
		{
			name:      "connection error is not fatal",
			stsErr:    &smithy.OperationError{ServiceID: "STS", OperationName: "AssumeRole", Err: errors.New("dial tcp: i/o timeout")},
			wantFatal: false,
			wantText:  []string{"i/o timeout"},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			stsClient := &mockSTSClient{err: tt.stsErr}
			p := newTestAssumeRoleProvider(&staticConfigProvider{cfg: baseConfig()}, AssumeRoleConfig{RoleArn: testRoleArn, RoleSessionName: "ns@sa"}, stsClient)
			cfg, err := p.GetAWSConfig(context.Background())
			if err != nil {
				t.Fatalf("unexpected error: %v", err)
			}

			sm := secretsmanager.NewFromConfig(cfg, func(o *secretsmanager.Options) {
				o.HTTPClient = noNetwork{t}
				o.Retryer = aws.NopRetryer{} // classification must not depend on retries
			})
			_, err = sm.GetSecretValue(context.Background(), &secretsmanager.GetSecretValueInput{SecretId: aws.String("MySecret")})
			if err == nil {
				t.Fatal("expected GetSecretValue to fail")
			}
			if got := utils.IsFatalError(err); got != tt.wantFatal {
				t.Fatalf("IsFatalError = %v, want %v for %v", got, tt.wantFatal, err)
			}
			for _, want := range tt.wantText {
				if !strings.Contains(err.Error(), want) {
					t.Errorf("error %q does not contain %q", err.Error(), want)
				}
			}
			if stsClient.input == nil {
				t.Fatal("AssumeRole was not called")
			}
		})
	}
}

func TestAssumeRoleError_PreservesCodeAndMessage(t *testing.T) {
	inner := stsAPIError(403, "AccessDenied", accessDeniedMessage)
	err := &AssumeRoleError{err: inner}

	var ae smithy.APIError
	if !errors.As(err, &ae) {
		t.Fatal("AssumeRoleError must implement smithy.APIError")
	}
	if ae.ErrorCode() != "AccessDenied" || ae.ErrorMessage() != accessDeniedMessage {
		t.Errorf("code/message = %q/%q, want AccessDenied/%q", ae.ErrorCode(), ae.ErrorMessage(), accessDeniedMessage)
	}
	if ae.ErrorFault() != smithy.FaultClient {
		t.Errorf("fault = %v, want client", ae.ErrorFault())
	}
	if !errors.Is(err, inner) {
		t.Error("AssumeRoleError must unwrap to the STS error")
	}
	if err.Error() != inner.Error() {
		t.Errorf("Error() = %q, want the STS text %q", err.Error(), inner.Error())
	}
}
