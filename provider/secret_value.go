package provider

import (
	"encoding/json"
	"fmt"

	"github.com/aws/secrets-store-csi-driver-provider-aws/utils"
	"github.com/jmespath/go-jmespath"
)

// Contains the actual contents of the secret fetched from either Secrete Manager
// or SSM Parameter Store along with the original descriptor.
type SecretValue struct {
	Value      []byte
	Descriptor SecretDescriptor
}

func (p *SecretValue) String() string { return "<REDACTED>" } // Do not log secrets
// parse out and return specified key value pairs from the secret
func (p *SecretValue) getJsonSecrets() (s []*SecretValue, e error) {

	jsonValues := make([]*SecretValue, 0)
	if len(p.Descriptor.JMESPath) == 0 {
		return jsonValues, nil
	}

	var data interface{}
	err := json.Unmarshal(p.Value, &data)
	if err != nil {
		return nil, &utils.JSONProcessingError{
			Message: fmt.Sprintf(
				`Failed to parse secret %q as JSON for JMESPath processing: %v`,
				p.Descriptor.ObjectName, err,
			),
		}
	}

	//fetch all specified key value pairs`
	for _, jmesPathEntry := range p.Descriptor.JMESPath {

		jsonSecret, err := jmespath.Search(jmesPathEntry.Path, data)

		if err != nil {
			return nil, &utils.JSONProcessingError{
				Message: fmt.Sprintf(
					`Invalid JMESPath %q for object alias %q in secret %q: %v`,
					jmesPathEntry.Path, jmesPathEntry.ObjectAlias, p.Descriptor.ObjectName, err,
				),
			}
		}

		if jsonSecret == nil {
			return nil, &utils.JSONProcessingError{
				Message: fmt.Sprintf(
					`JMESPath %q for object alias %q was not found in secret %q`,
					jmesPathEntry.Path, jmesPathEntry.ObjectAlias, p.Descriptor.ObjectName,
				),
			}
		}

		jsonSecretAsString, isString := jsonSecret.(string)

		if !isString {
			return nil, &utils.JSONProcessingError{
				Message: fmt.Sprintf(
					`JMESPath %q for object alias %q in secret %q returned a non-string value. Only string values are supported`,
					jmesPathEntry.Path, jmesPathEntry.ObjectAlias, p.Descriptor.ObjectName,
				),
			}
		}

		descriptor := p.Descriptor.getJmesEntrySecretDescriptor(&jmesPathEntry)

		secretValue := SecretValue{
			Value:      []byte(jsonSecretAsString),
			Descriptor: descriptor,
		}
		jsonValues = append(jsonValues, &secretValue)

	}
	return jsonValues, nil
}
