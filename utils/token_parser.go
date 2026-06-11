package utils

import (
	"encoding/json"
	"fmt"
)

const (
	// IRSAAudience is the token audience for IAM Roles for Service Accounts.
	IRSAAudience = "sts.amazonaws.com"
	// PodIdentityAudience is the token audience for EKS Pod Identity.
	PodIdentityAudience = "pods.eks.amazonaws.com"
)

type ServiceAccountToken struct {
	Token               string `json:"token"`
	ExpirationTimestamp string `json:"expirationTimestamp"`
}

// ParseServiceAccountTokens parses the CSI driver's serviceAccount.tokens JSON.
func ParseServiceAccountTokens(tokensJSON string) (map[string]ServiceAccountToken, error) {
	if tokensJSON == "" {
		return nil, fmt.Errorf("serviceAccount.tokens not provided - ensure tokenRequests is configured in CSIDriver")
	}
	var tokens map[string]ServiceAccountToken
	if err := json.Unmarshal([]byte(tokensJSON), &tokens); err != nil {
		return nil, fmt.Errorf("failed to parse serviceAccount.tokens: %w", err)
	}
	return tokens, nil
}

// GetTokenForAudience extracts a non-empty token for a specific audience from a parsed token map.
func GetTokenForAudience(tokens map[string]ServiceAccountToken, audience string) (string, error) {
	t, ok := tokens[audience]
	if !ok {
		return "", fmt.Errorf("token for audience %q not found - ensure tokenRequests includes this audience in CSIDriver", audience)
	}
	if t.Token == "" {
		return "", fmt.Errorf("token for audience %q is empty", audience)
	}
	return t.Token, nil
}
