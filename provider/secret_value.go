package provider

import (
	"encoding/base64"
	"encoding/json"
	"fmt"
	"strings"

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
		return nil, fmt.Errorf("Invalid JSON used with jmesPath in secret: %s.", p.Descriptor.ObjectName)
	}

	//fetch all specified key value pairs
	for _, jmesPathEntry := range p.Descriptor.JMESPath {
		jsonSecret, err := jmespath.Search(jmesPathEntry.Path, data)

		if err != nil {
			return nil, fmt.Errorf("Invalid JMES Path: %s.", jmesPathEntry.Path)
		}

		if jsonSecret == nil {
			return nil, fmt.Errorf("JMES Path - %s for object alias - %s does not point to a valid object.",
				jmesPathEntry.Path, jmesPathEntry.ObjectAlias)
		}

		jsonSecretAsString, isString := jsonSecret.(string)

		if !isString {
			return nil, fmt.Errorf("Invalid JMES search result type for path:%s. Only string is allowed.", jmesPathEntry.Path)
		}

		descriptor := p.Descriptor.getJmesEntrySecretDescriptor(&jmesPathEntry)
		value := []byte(jsonSecretAsString)

		// Process the value based on its encoding
		if descriptor.ObjectEncoding != "" {
			switch strings.ToLower(descriptor.ObjectEncoding) {
			case "base64":
				decodedValue, err := base64.StdEncoding.DecodeString(jsonSecretAsString)
				if err != nil {
					return nil, fmt.Errorf("failed to decode base64 value for JMES path %s in secret %s: %w",
						jmesPathEntry.Path, p.Descriptor.ObjectName, err)
				}
				value = decodedValue
			default:
				return nil, fmt.Errorf("unsupported encoding type %s for JMES path %s in secret %s",
					descriptor.ObjectEncoding, jmesPathEntry.Path, p.Descriptor.ObjectName)
			}
		}

		secretValue := SecretValue{
			Value:      value,
			Descriptor: descriptor,
		}
		jsonValues = append(jsonValues, &secretValue)
	}
	return jsonValues, nil
}
