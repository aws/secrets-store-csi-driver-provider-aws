package credential_provider

import (
	"time"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/credentials/stscreds"
	"github.com/aws/aws-sdk-go-v2/service/sts"
)

// WithAssumeRole returns a copy of cfg whose credentials come from assuming
// roleArn. The base credentials already in cfg (IRSA or Pod Identity) are used
// to call STS AssumeRole. A zero duration and empty externalID use the SDK defaults.
func WithAssumeRole(cfg aws.Config, roleArn string, duration time.Duration, externalID string) aws.Config {
	stsClient := sts.NewFromConfig(cfg)

	var optFns []func(*stscreds.AssumeRoleOptions)
	if duration > 0 {
		optFns = append(optFns, func(o *stscreds.AssumeRoleOptions) { o.Duration = duration })
	}
	if externalID != "" {
		optFns = append(optFns, func(o *stscreds.AssumeRoleOptions) { o.ExternalID = aws.String(externalID) })
	}

	cfg.Credentials = aws.NewCredentialsCache(stscreds.NewAssumeRoleProvider(stsClient, roleArn, optFns...))
	return cfg
}
