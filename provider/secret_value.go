package provider

import (
	"bytes"
	"encoding/json"
	"fmt"
	"text/template"

	"github.com/jmespath/go-jmespath"
)

// Contains the actual contents of the secret fetched from either Secrete Manager
// or SSM Parameter Store along with the original descriptor.
type SecretValue struct {
	Value      []byte
	Descriptor SecretDescriptor
}

func (p *SecretValue) String() string { return "<REDACTED>" } // Do not log secrets
//parse out and return specified key value pairs from the secret
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

	//fetch all specified key value pairs`
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

		secretValue := SecretValue{
			Value:      []byte(jsonSecretAsString),
			Descriptor: descriptor,
		}
		jsonValues = append(jsonValues, &secretValue)

	}
	return jsonValues, nil
}

func (p *SecretValue) getTemplatedSecrets() (*SecretValue, error) {

	var data interface{}
	err := json.Unmarshal(p.Value, &data)
	if err != nil {
		return nil, fmt.Errorf("Invalid JSON used with template in secret: %s", p.Descriptor.ObjectName)
	}

	objectTemplate := p.Descriptor.ObjectTemplate
	t, err := template.New("secretTemplate").Parse(objectTemplate)
	if err != nil {
		return nil, fmt.Errorf("Invalid template %s", objectTemplate)
	}

	var result bytes.Buffer
	err = t.Execute(&result, data)
	if err != nil {
		return nil, err
	}
	secretValue := SecretValue{
		Value:      result.Bytes(),
		Descriptor: p.Descriptor,
	}
	return &secretValue, nil
}