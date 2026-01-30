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
	tests := []struct {
		name      string
		input     string
		audience  string
		wantToken string
		wantErr   bool
	}{
		{
			name:    "empty string",
			input:   "",
			wantErr: true,
		},
		{
			name:      "valid - sts audience",
			input:     validTokensJSON,
			audience:  "sts.amazonaws.com",
			wantToken: "irsa-test-token",
			wantErr:   false,
		},
		{
			name:      "valid - pod identity audience",
			input:     validTokensJSON,
			audience:  "pods.eks.amazonaws.com",
			wantToken: "pod-identity-test-token",
			wantErr:   false,
		},
		{
			name:     "audience not found",
			input:    validTokensJSON,
			audience: "unknown.audience.com",
			wantErr:  true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			token, err := GetTokenForAudience(tt.input, tt.audience)
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
