package credential_provider

import (
	"fmt"
	"time"

	"github.com/aws/aws-sdk-go-v2/credentials/endpointcreds"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/jellydator/ttlcache/v3"
)

type TokenCacheValue string

func (v *TokenCacheValue) GoString() string { return "<redacted>" }
func (v *TokenCacheValue) String() string   { return "<redacted>" }

// SetTokenCacheValue sets a token in the cache for a given volume and region.
func SetTokenCacheValue(
	cache *ttlcache.Cache[string, TokenCacheValue],
	volumeID, region, token string,
	tokenExpiresAt time.Time) {

	cacheKey := fmt.Sprintf("%s:%s", volumeID, region)
	cacheExpiry := time.Hour
	if tokenExpiresAt.Before(time.Now().Add(cacheExpiry)) {
		cacheExpiry = time.Until(tokenExpiresAt)
		// if cache expiry is negative, don't set the cache value
		if cacheExpiry < 0 {
			return
		}
	}

	cache.Set(cacheKey, TokenCacheValue(token), cacheExpiry)
}

// TokenFetcher is a function that fetches a token from a cache.
// It satisfies both the stscreds.IdentityTokenRetriever and endpointcreds.AuthTokenProvider interfaces.
type TokenFetcher func() (string, error)

// NewTokenFetcher returns a TokenFetcherFunc that fetches a token from the cache.
func NewTokenFetcher(cache *ttlcache.Cache[string, TokenCacheValue], volumeID, region string) TokenFetcher {
	return func() (string, error) {
		cacheKey := fmt.Sprintf("%s:%s", volumeID, region)
		ok := cache.Has(cacheKey)
		if !ok {
			return "", fmt.Errorf("token not found in cache")
		}

		val := cache.Get(cacheKey).Value()

		return string(val), nil
	}
}

// GetIdentityToken retrieves a token from the cache and satisfies the stscreds.IdentityTokenRetriever interface.
func (f TokenFetcher) GetIdentityToken() ([]byte, error) {
	tok, err := f()
	if err != nil {
		return nil, err
	}

	return []byte(tok), nil
}

// GetToken retrieves a token from the cache and satisfies the endpointcreds.AuthTokenProvider interface.
func (f TokenFetcher) GetToken() (string, error) {
	return f()
}

// validate that the TokenFetcherFunc satisfies the stscreds.IdentityTokenRetriever and endpointcreds.AuthTokenProvider interfaces
var _ stscreds.IdentityTokenRetriever = NewTokenFetcher(nil, "", "")
var _ endpointcreds.AuthTokenProvider = NewTokenFetcher(nil, "", "")
