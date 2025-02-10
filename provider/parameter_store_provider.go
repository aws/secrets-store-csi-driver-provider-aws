package provider

import (
	"context"
	"fmt"
	"strconv"
	"strings"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/awserr"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/ssm"
	"github.com/aws/aws-sdk-go/service/ssm/ssmiface"
	"github.com/aws/secrets-store-csi-driver-provider-aws/utils"
	"k8s.io/klog/v2"

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
type ParameterStoreProvider struct {
	clients []ParameterStoreClient
}

// Parameterstore client with region
type ParameterStoreClient struct {
	IsFailover bool
	Region     string
	Client     ssmiface.SSMAPI
}

// Get the secret from Parameter Store.
//
// This method iterates over the requested secrets build up batches of requests
// and fetching them. As each batch is fetched, the results are saved and the
// current version map (curMap) is updated with the current version information.
func (p *ParameterStoreProvider) GetSecretValues(
	ctx context.Context,
	descriptors []*SecretDescriptor,
	curMap map[string]*v1alpha1.ObjectVersion,
) (v []*SecretValue, e error) {

	// Fetch parameters in batches and build up the results in values
	descLen := len(descriptors)
	for i := 0; i < descLen; i += batchSize {

		end := min(i+batchSize, descLen) // Calculate slice end.
		batchDescriptors := descriptors[i:end]

		batchValues, batchErrors := p.fetchParameterStoreValue(ctx, batchDescriptors, curMap)
		if batchErrors != nil {
			return nil, batchErrors
		}
		v = append(v, batchValues...)
	}
	return v, nil
}

// Private helper function to fetch a batch secret.
//
// This method iterates over all available clients in the ParameterProvider.
// It requests a fetch from each of them.  Once a fetch succeeds it returns the
// value. If a fetch fails in all clients it returns all errors.
func (p *ParameterStoreProvider) fetchParameterStoreValue(
	ctx context.Context,
	batchDescriptors []*SecretDescriptor,
	curMap map[string]*v1alpha1.ObjectVersion,
) (values []*SecretValue, err error) {

	for _, client := range p.clients {
		batchValues, err := p.fetchParameterStoreBatch(ctx, client, batchDescriptors, curMap)

		if utils.IsFatalError(err) {
			return nil, err
		} else if err != nil {
			klog.Warning(err)
		}

		if len(values) == 0 {
			values = batchValues
		}
	}
	if values == nil {
		return nil, fmt.Errorf("failed to fetch parameters from all regions")
	}

	return values, nil
}

// Private helper function to fetch batch of secrets from a single region
//
// This method builds batch of parameters and fetches the values.
// if any parameter is failed to fetch, the parameter is returned as invalid parameter
// and the version information is updated in the current version map.
func (p *ParameterStoreProvider) fetchParameterStoreBatch(
	ctx context.Context,
	client ParameterStoreClient,
	batchDescriptors []*SecretDescriptor,
	curMap map[string]*v1alpha1.ObjectVersion,
) (v []*SecretValue, err error) {

	var values []*SecretValue

	// Build up the batch of parameter names.
	var names []*string
	batchDesc := make(map[string]*SecretDescriptor)
	for _, descriptor := range batchDescriptors {

		// Use either version or label if specified (but not both)
		parameterName := descriptor.GetSecretName(client.IsFailover)
		if len(descriptor.GetObjectVersion(client.IsFailover)) != 0 {
			parameterName = fmt.Sprintf("%s:%s", parameterName, descriptor.GetObjectVersion(client.IsFailover))
		} else if len(descriptor.GetObjectVersionLabel(client.IsFailover)) != 0 {
			parameterName = fmt.Sprintf("%s:%s", parameterName, descriptor.GetObjectVersionLabel(client.IsFailover))
		}

		names = append(names, aws.String(parameterName))
		batchDesc[descriptor.GetSecretName(client.IsFailover)] = descriptor // Needed for response
	}

	// Fetch the batch of secrets
	rsp, err := client.Client.GetParametersWithContext(ctx, &ssm.GetParametersInput{
		Names:          names,
		WithDecryption: aws.Bool(true),
	})
	if err != nil {
		return nil, fmt.Errorf("%s: Failed fetching parameters: %w", client.Region, err)
	}

	if len(rsp.InvalidParameters) != 0 {
		err = awserr.NewRequestFailure(awserr.New("", fmt.Sprintf("%s: invalid parameters: %s", client.Region, strings.Join(aws.StringValueSlice(rsp.InvalidParameters), ", ")), err), 400, "")
		return nil, err
	}

	// Build up the results from the batch
	for _, parm := range rsp.Parameters {

		// SecretDescriptor key is either Name or ARN.
		descriptor := batchDesc[*(parm.Name)]
		if descriptor == nil {
			descriptor = batchDesc[*(parm.ARN)]
		}

		secretValue := &SecretValue{
			Value:      []byte(*(parm.Value)),
			Descriptor: *descriptor,
		}
		values = append(values, secretValue)

		//Fetch individual json key value pairs if jmesPath is specified
		jsonSecrets, jsonErr := secretValue.getJsonSecrets()
		if jsonErr != nil {
			return nil, fmt.Errorf("%s: %s", client.Region, jsonErr)
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

	return values, nil
}

// Factory methods to build a new ParameterStoreProvider
func NewParameterStoreProviderWithClients(clients ...ParameterStoreClient) *ParameterStoreProvider {
	return &ParameterStoreProvider{
		clients: clients,
	}
}

func NewParameterStoreProvider(awsSessions []*session.Session, regions []string) *ParameterStoreProvider {
	var parameterStoreClients []ParameterStoreClient
	for i, awsSession := range awsSessions {
		client := ParameterStoreClient{
			Region:     *awsSession.Config.Region,
			Client:     ssm.New(awsSession, aws.NewConfig().WithRegion(regions[i])),
			IsFailover: i > 0,
		}
		parameterStoreClients = append(parameterStoreClients, client)
	}
	return NewParameterStoreProviderWithClients(parameterStoreClients...)
}

// Private implementation of min using ints because math.Min uses floats only.
func min(i, j int) int {
	if i > j {
		return j
	}
	return i
}
