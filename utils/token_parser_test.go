package utils

import (
	"testing"
)

const validTokensJSON = `{
  "sts.amazonaws.com": {
    "token": "irsa-test-token",
    "expirationTimestamp": "2024-01-15T10:30:00Z"
  },
  "pods.eks.amazonaws.com": {
    "token": "pod-identity-test-token",
    "expirationTimestamp": "2024-01-15T10:30:00Z"
  }
}`

func mustParseTokens(t *testing.T, tokensJSON string) map[string]ServiceAccountToken {
	t.Helper()
	tokens, err := ParseServiceAccountTokens(tokensJSON)
	if err != nil {
		t.Fatalf("failed to parse tokens: %v", err)
	}
	return tokens
}

func TestParseServiceAccountTokens(t *testing.T) {
	tests := []struct {
		name      string
		input     string
		wantErr   bool
		wantCount int
	}{
		{
			name:    "empty string",
			input:   "",
			wantErr: true,
		},
		{
			name:    "invalid JSON",
			input:   "not json",
			wantErr: true,
		},
		{
			name:      "valid JSON with multiple audiences",
			input:     validTokensJSON,
			wantErr:   false,
			wantCount: 2,
		},
		{
			name:      "valid JSON with single audience",
			input:     `{"sts.amazonaws.com": {"token": "test", "expirationTimestamp": "2024-01-15T10:30:00Z"}}`,
			wantErr:   false,
			wantCount: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			tokens, err := ParseServiceAccountTokens(tt.input)
			if (err != nil) != tt.wantErr {
				t.Errorf("ParseServiceAccountTokens() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr && len(tokens) != tt.wantCount {
				t.Errorf("ParseServiceAccountTokens() got %d tokens, want %d", len(tokens), tt.wantCount)
			}
		})
	}
}

func TestGetTokenForAudience(t *testing.T) {
	validTokens := mustParseTokens(t, validTokensJSON)
	emptyTokenMap := map[string]ServiceAccountToken{
		"sts.amazonaws.com": {Token: "", ExpirationTimestamp: "2024-01-15T10:30:00Z"},
	}

	tests := []struct {
		name      string
		tokens    map[string]ServiceAccountToken
		audience  string
		wantToken string
		wantErr   bool
	}{
		{
			name:      "valid - sts audience",
			tokens:    validTokens,
			audience:  "sts.amazonaws.com",
			wantToken: "irsa-test-token",
			wantErr:   false,
		},
		{
			name:      "valid - pod identity audience",
			tokens:    validTokens,
			audience:  "pods.eks.amazonaws.com",
			wantToken: "pod-identity-test-token",
			wantErr:   false,
		},
		{
			name:     "audience not found",
			tokens:   validTokens,
			audience: "unknown.audience.com",
			wantErr:  true,
		},
		{
			name:     "empty token value",
			tokens:   emptyTokenMap,
			audience: "sts.amazonaws.com",
			wantErr:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			token, err := GetTokenForAudience(tt.tokens, tt.audience)
			if (err != nil) != tt.wantErr {
				t.Errorf("GetTokenForAudience() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if !tt.wantErr && token != tt.wantToken {
				t.Errorf("GetTokenForAudience() got %q, want %q", token, tt.wantToken)
			}
		})
	}
}

func TestAudienceConstants(t *testing.T) {
	if IRSAAudience != "sts.amazonaws.com" {
		t.Errorf("IRSAAudience = %q, want %q", IRSAAudience, "sts.amazonaws.com")
	}
	if PodIdentityAudience != "pods.eks.amazonaws.com" {
		t.Errorf("PodIdentityAudience = %q, want %q", PodIdentityAudience, "pods.eks.amazonaws.com")
	}
}
