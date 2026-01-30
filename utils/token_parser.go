package utils

import (
	"encoding/json"
	"fmt"
)

type ServiceAccountToken struct {
	Token               string `json:"token"`
	ExpirationTimestamp string `json:"expirationTimestamp"`
}

// ParseServiceAccountTokens parses the CSI driver's serviceAccount.tokens JSON
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

// GetTokenForAudience extracts token for a specific audience, returns error if not found
func GetTokenForAudience(tokensJSON, audience string) (string, error) {
	tokens, err := ParseServiceAccountTokens(tokensJSON)
	if err != nil {
		return "", err
	}
	if t, ok := tokens[audience]; ok {
		return t.Token, nil
	}
	return "", fmt.Errorf("token for audience %q not found - ensure tokenRequests includes this audience in CSIDriver", audience)
}
