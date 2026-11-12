package credential_provider

import (
	"context"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials"
)

const assumeRoleResponseXML = `<AssumeRoleResponse xmlns="https://sts.amazonaws.com/doc/2011-06-15/">
<AssumeRoleResult>
<Credentials>
<AccessKeyId>ASSUMED_AKID</AccessKeyId>
<SecretAccessKey>ASSUMED_SECRET</SecretAccessKey>
<SessionToken>ASSUMED_TOKEN</SessionToken>
<Expiration>2099-01-01T00:00:00Z</Expiration>
</Credentials>
<AssumedRoleUser>
<Arn>arn:aws:sts::123456789012:assumed-role/TestRole/session</Arn>
<AssumedRoleId>AROATEST:session</AssumedRoleId>
</AssumedRoleUser>
</AssumeRoleResult>
<ResponseMetadata><RequestId>test-request</RequestId></ResponseMetadata>
</AssumeRoleResponse>`

func TestWithAssumeRole(t *testing.T) {
	// The SDK sends DurationSeconds=900 when no duration is set.
	tests := []struct {
		name             string
		duration         time.Duration
		externalID       string
		wantDurationSecs string
		wantExternalID   string
	}{
		{
			name:             "default duration and no external id",
			wantDurationSecs: "900",
		},
		{
			name:             "custom duration",
			duration:         time.Hour,
			wantDurationSecs: "3600",
		},
		{
			name:             "custom duration and external id",
			duration:         15 * time.Minute,
			externalID:       "ext-123",
			wantDurationSecs: "900",
			wantExternalID:   "ext-123",
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var form url.Values
			server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				body, _ := io.ReadAll(r.Body)
				form, _ = url.ParseQuery(string(body))
				w.Header().Set("Content-Type", "text/xml")
				_, _ = io.WriteString(w, assumeRoleResponseXML)
			}))
			defer server.Close()

			baseCfg := aws.Config{
				Region:       "us-west-2",
				Credentials:  credentials.NewStaticCredentialsProvider("BASE_AKID", "BASE_SECRET", ""),
				BaseEndpoint: aws.String(server.URL),
			}
			roleArn := "arn:aws:iam::123456789012:role/TestRole"

			cfg := WithAssumeRole(baseCfg, roleArn, tt.duration, tt.externalID)

			creds, err := cfg.Credentials.Retrieve(context.Background())
			if err != nil {
				t.Fatalf("Retrieve returned error: %v", err)
			}
			if creds.AccessKeyID != "ASSUMED_AKID" {
				t.Errorf("expected assumed role credentials, got AccessKeyID %q", creds.AccessKeyID)
			}
			if form.Get("Action") != "AssumeRole" {
				t.Fatalf("expected AssumeRole action, got %q", form.Get("Action"))
			}
			if form.Get("RoleArn") != roleArn {
				t.Errorf("expected RoleArn %q, got %q", roleArn, form.Get("RoleArn"))
			}
			if got := form.Get("DurationSeconds"); got != tt.wantDurationSecs {
				t.Errorf("expected DurationSeconds %q, got %q", tt.wantDurationSecs, got)
			}
			if got := form.Get("ExternalId"); got != tt.wantExternalID {
				t.Errorf("unexpected ExternalId %q", got)
			}
		})
	}
}
