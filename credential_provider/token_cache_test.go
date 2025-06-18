package credential_provider

import (
	"fmt"
	"testing"
	"time"

	"github.com/jellydator/ttlcache/v3"
)

func NewMockTokenFetcher(token string, err error) TokenFetcher {
	return func() (string, error) { return token, err }
}

func TestTokenCache(t *testing.T) {
	cases := []struct {
		name        string
		token       string
		volumeID    string
		region      string
		lookupVolID string
		err         error
	}{
		{"TestTokenCache", "testToken", "testVolumeID", "testRegion", "testVolumeID", nil},
		{"TestTokenCacheError", "testToken", "testVolumeID", "testRegion", "NotAVolumeID", fmt.Errorf("token not found in cache")},
	}

	for _, tt := range cases {
		t.Run(tt.name, func(t *testing.T) {
			cache := ttlcache.New[string, TokenCacheValue](ttlcache.WithTTL[string, TokenCacheValue](time.Minute))

			tokenExpiresAt := time.Now().Add(time.Minute)

			SetTokenCacheValue(cache, tt.volumeID, tt.region, tt.token, tokenExpiresAt)
			tokenFetcher := NewTokenFetcher(cache, tt.lookupVolID, tt.region)
			token, err := tokenFetcher()
			if err != nil && tt.err == nil {
				t.Fatalf("expected no error, got %v", err)
			}
			if err == nil && tt.err != nil {
				t.Fatalf("expected error, got no error")
			}
			if err != nil && tt.err != nil {
				if err.Error() != tt.err.Error() {
					t.Fatalf("expected error %v, got %v", tt.err, err)
				}
				return
			}
			if token != tt.token {
				t.Errorf("expected token %s, got %s", tt.token, token)
			}
		})
	}
}
