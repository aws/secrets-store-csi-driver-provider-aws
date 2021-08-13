package provider

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ssm"
	"github.com/aws/aws-sdk-go/service/ssm/ssmiface"

	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"
)

const (
	batchSize = 10 // Max parameters SSM allows in a batch.
)

// Implements the provider interface for SSM Parameter Store.
//
// Unlike the SecretsManagerProvider, this implementation is optimized to
// reduce API call rates rather than latency in order to avoid request
// throttling (which would result in higher latency).
//
// This implementation reduces API calls by batching multiple parameter requests
// together using the GetParameters call.
//
type ParameterStoreProvider struct {
	client ssmiface.SSMAPI
}

// Get the secret from Parameter Store.
//
// This method iterates over the requested secrets build up batches of requests
// and fetching them. As each batch is fetched, the results are saved and the
// current version map (curMap) is updated with the current version information.
//
func (p *ParameterStoreProvider) GetSecretValues(
	ctx context.Context,
	descriptors []*SecretDescriptor,
	curMap map[string]*v1alpha1.ObjectVersion,
) (v []*SecretValue, e error) {

	// Fetch parameters in batches and build up the results in values
	var values []*SecretValue
	descLen := len(descriptors)
	for i := 0; i < descLen; i += batchSize {

		end := min(i+batchSize, descLen) // Calculate slice end.

		// Build up the batch of parameter names.
		var names []*string
		batchDesc := make(map[string]*SecretDescriptor)
		for _, descriptor := range descriptors[i:end] {

			// Use either version or label if specified (but not both)
			parameterName := descriptor.ObjectName
			if len(descriptor.ObjectVersion) != 0 {
				parameterName = fmt.Sprintf("%s:%s", parameterName, descriptor.ObjectVersion)
			} else if len(descriptor.ObjectVersionLabel) != 0 {
				parameterName = fmt.Sprintf("%s:%s", parameterName, descriptor.ObjectVersionLabel)
			}

			names = append(names, aws.String(parameterName))
			batchDesc[descriptor.ObjectName] = descriptor // Needed for response

		}

		// Fetch the batch of secrets
		rsp, err := p.client.GetParametersWithContext(ctx, &ssm.GetParametersInput{
			Names:          names,
			WithDecryption: aws.Bool(true),
		})
		if err != nil {
			return nil, fmt.Errorf("Failed fetching parameters: %s", err.Error())
		}
		if len(rsp.InvalidParameters) != 0 { // Convert []*string to []string for the error message
			return nil, fmt.Errorf("Invalid parameters: %s", strings.Join(aws.StringValueSlice(rsp.InvalidParameters), ", "))
		}

		// Build up the results from the batch response
		for _, parm := range rsp.Parameters {

			descriptor := batchDesc[*(parm.Name)]

			secretValue := &SecretValue{
				Value:      []byte(*(parm.Value)),
				Descriptor: *descriptor,
			}
			values = append(values, secretValue)

			//Fetch individual json key value pairs if jmesPath is specified
			jsonSecrets, err := secretValue.getJsonSecrets()
			if err != nil {
				return nil, err
			}

			values = append(values, jsonSecrets...)

			// Update the version in the current version map.
			for _, jsonSecret := range jsonSecrets {
				jsonDescriptor := jsonSecret.Descriptor
				curMap[jsonDescriptor.GetFileName()] = &v1alpha1.ObjectVersion{
					Id:      jsonDescriptor.GetFileName(),
					Version: strconv.Itoa(int(*(parm.Version))),
				}
			}

			curMap[descriptor.GetFileName()] = &v1alpha1.ObjectVersion{
				Id:      descriptor.GetFileName(),
				Version: strconv.Itoa(int(*(parm.Version))),
			}

		}

	}

	return values, nil
}

// Factory methods to build a new ParameterStoreProvider
//
func NewParameterStoreProviderWithClient(client ssmiface.SSMAPI) *ParameterStoreProvider {
	return &ParameterStoreProvider{
		client: client,
	}
}
func NewParameterStoreProvider(region string, awsSession *session.Session) *ParameterStoreProvider {
	parameterStoreClient := ssm.New(awsSession, aws.NewConfig().WithRegion(region))
	return NewParameterStoreProviderWithClient(parameterStoreClient)
}

// Private implementation of min using ints because math.Min uses floats only.
func min(i, j int) int {
	if i > j {
		return j
	}
	return i
}
