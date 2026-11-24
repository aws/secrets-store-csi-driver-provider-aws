package credential_provider

import (
	"context"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/sts"
)

func TestNewIRSACredentialProvider(t *testing.T) {
	provider, err := NewIRSACredentialProvider(
		"someRegion",
		"arn:aws:iam::123456789012:role/test-role",
		"test-app-id",
		"irsa-test-token",
	)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if provider == nil {
		t.Fatal("Expected provider to be non-nil")
	}
}

func TestCSITokenFetcher(t *testing.T) {
	fetcher := &csiTokenFetcher{token: "test-token"}
	token, err := fetcher.GetIdentityToken()
	if err != nil {
		t.Errorf("Unexpected error: %v", err)
	}
	if string(token) != "test-token" {
		t.Errorf("Expected token %q, got %q", "test-token", string(token))
	}
}

func TestIRSACredentialProvider_GetAWSConfig(t *testing.T) {
	provider, err := NewIRSACredentialProvider(
		"someRegion",
		"arn:aws:iam::123456789012:role/test-role",
		"test-app-id",
		"irsa-test-token",
	)
	if err != nil {
		t.Fatalf("Failed to create provider: %v", err)
	}

	cfg, err := provider.GetAWSConfig(context.Background())

	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if cfg.Region != "someRegion" {
		t.Errorf("Region = %q, want someRegion", cfg.Region)
	}
	if cfg.Credentials == nil {
		t.Error("Expected credentials to be non-nil")
	}
}

func TestIRSACredentialProvider_STSClientUsesLoadedConfig(t *testing.T) {
	const roleARN = "arn:aws:iam::123456789012:role/test-role"
	t.Setenv("AWS_CONFIG_FILE", os.DevNull)
	t.Setenv("AWS_SHARED_CREDENTIALS_FILE", os.DevNull)
	t.Setenv("AWS_PROFILE", "")
	t.Setenv("AWS_DEFAULT_PROFILE", "")
	t.Setenv("AWS_ENDPOINT_URL", "")
	t.Setenv("AWS_IGNORE_CONFIGURED_ENDPOINT_URLS", "false")

	tests := []struct {
		name        string
		fips        string
		dualStack   string
		endpointURL string
		wantHost    string
	}{
		{name: "default endpoint", wantHost: "sts.us-west-2.amazonaws.com"},
		{name: "FIPS endpoint", fips: "true", wantHost: "sts-fips.us-west-2.amazonaws.com"},
		{name: "dual-stack endpoint", dualStack: "true", wantHost: "sts.us-west-2.api.aws"},
		{name: "FIPS dual-stack endpoint", fips: "true", dualStack: "true", wantHost: "sts-fips.us-west-2.api.aws"},
		{name: "STS endpoint override", endpointURL: "https://sts.vpce.example.com", wantHost: "sts.vpce.example.com"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			t.Setenv("AWS_ENDPOINT_URL_STS", tt.endpointURL)
			t.Setenv("AWS_USE_FIPS_ENDPOINT", tt.fips)
			t.Setenv("AWS_USE_DUALSTACK_ENDPOINT", tt.dualStack)

			provider, err := NewIRSACredentialProvider("us-west-2", roleARN, "test-app-id", "irsa-test-token")
			if err != nil {
				t.Fatal(err)
			}
			recorder := &stsRequestRecorder{}
			provider.(*IRSACredentialProvider).stsOptions = []func(*sts.Options){recorder.configure}

			cfg, err := provider.GetAWSConfig(t.Context())
			if err != nil {
				t.Fatal(err)
			}
			if !aws.IsCredentialsProvider(recorder.credentials, aws.AnonymousCredentials{}) {
				t.Fatalf("STS credentials = %T, want anonymous", recorder.credentials)
			}
			creds, err := cfg.Credentials.Retrieve(t.Context())
			if err != nil {
				t.Fatal(err)
			}
			if creds.AccessKeyID != "test-key" || creds.SecretAccessKey != "test-secret" || creds.SessionToken != "test-session" {
				t.Error("expected credentials from the STS response")
			}

			req := recorder.request
			if req == nil {
				t.Fatal("AssumeRoleWithWebIdentity was not called")
			}
			if got := req.URL.Host; got != tt.wantHost {
				t.Errorf("STS host = %q, want %q", got, tt.wantHost)
			}
			if ua := req.UserAgent(); !strings.Contains(ua, "app/test-app-id") {
				t.Errorf("User-Agent %q does not carry the app ID", ua)
			}
			if got := req.PostForm.Get("Action"); got != "AssumeRoleWithWebIdentity" {
				t.Errorf("Action = %q, want AssumeRoleWithWebIdentity", got)
			}
			if got := req.PostForm.Get("RoleArn"); got != roleARN {
				t.Errorf("RoleArn = %q, want %q", got, roleARN)
			}
			if got := req.PostForm.Get("WebIdentityToken"); got != "irsa-test-token" {
				t.Errorf("WebIdentityToken = %q, want the CSI token", got)
			}
		})
	}
}

type stsRequestRecorder struct {
	credentials aws.CredentialsProvider
	request     *http.Request
}

func (r *stsRequestRecorder) configure(o *sts.Options) {
	r.credentials = o.Credentials
	o.HTTPClient = r
}

func (r *stsRequestRecorder) Do(req *http.Request) (*http.Response, error) {
	if err := req.ParseForm(); err != nil {
		return nil, err
	}
	r.request = req
	const response = `<AssumeRoleWithWebIdentityResponse><AssumeRoleWithWebIdentityResult><Credentials>
		<AccessKeyId>test-key</AccessKeyId>
		<SecretAccessKey>test-secret</SecretAccessKey>
		<SessionToken>test-session</SessionToken>
		<Expiration>2099-01-01T00:00:00Z</Expiration>
	</Credentials></AssumeRoleWithWebIdentityResult></AssumeRoleWithWebIdentityResponse>`
	return &http.Response{StatusCode: http.StatusOK, Body: io.NopCloser(strings.NewReader(response))}, nil
}
