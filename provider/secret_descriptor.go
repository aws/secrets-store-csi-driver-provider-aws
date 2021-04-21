package provider

import (
	"fmt"
	"strings"

	"github.com/aws/aws-sdk-go/aws/arn"
	"sigs.k8s.io/yaml"
)

// An individual record from the mount request indicating the secret to be
// fetched and mounted.
type SecretDescriptor struct {

	// Name of the secret
	ObjectName string `json:"objectName"`

	// Optional base file name in which to store the secret (use ObjectName if nil).
	ObjectAlias string `json:"objectAlias"`

	// Optional version id of the secret (default to latest).
	ObjectVersion string `json:"objectVersion"`

	// Optional version/stage label of the secret (defaults to latest).
	ObjectVersionLabel string `json:"objectVersionLabel"`

	// One of secretsmanager or ssmparameter (not required when using full secrets manager ARN).
	ObjectType string `json:"objectType"`
}

// Enum of supported secret types
//
type SecretType int

const (
	SSMParameter SecretType = iota
	SecretsManager
)

func (sType SecretType) String() string {
	return []string{"ssmparameter", "secretsmanager"}[sType]
}

// Private map of allowed objectType and associated ARN type. Used for
// validating and converting ARNs and objectType.
var typeMap = map[string]SecretType{
	"secretsmanager": SecretsManager,
	"ssmparameter":   SSMParameter,
	"ssm":            SSMParameter,
}

// Returns the file name where the secrets are to be written.
//
// Uses either the ObjectName or ObjectAlias to construct the file name.
//
func (p *SecretDescriptor) GetFileName() (path string) {
	if len(p.ObjectAlias) != 0 {
		return p.ObjectAlias
	}
	return p.ObjectName
}

// Returns the secret type (ssmparameter or secretsmanager).
//
// If the ObjectType is not specified, a full ARN must be present in the
// ObjectName so this method pulls the type from the ARN when ObjectType is
// not specified.
//
func (p *SecretDescriptor) GetSecretType() (stype SecretType) {

	// If no objectType, use ARN (but convert ssm to ssmparameter). Note that
	// SSM does not actually allow ARNs but we convert anyway for other checks.
	sType := p.ObjectType
	if len(sType) == 0 {
		sType = strings.Split(p.ObjectName, ":")[2] // Other checks garuntee ARN
	}

	return typeMap[sType]
}

// Private helper to validate the contents of SecretDescriptor.
//
// This method is used to validate input before it is used by the rest of the
// plugin.
//
func (p *SecretDescriptor) validateSecretDescriptor() error {

	if len(p.ObjectName) == 0 {
		return fmt.Errorf("Object name must be specified")
	}

	var objARN arn.ARN
	var err error
	hasARN := strings.HasPrefix(p.ObjectName, "arn:")
	if hasARN {
		objARN, err = arn.Parse(p.ObjectName)
		if err != nil {
			return fmt.Errorf("Invalid ARN format in object name: %s", p.ObjectName)
		}
	}

	// Make sure either objectType is used or a full ARN is specified
	if len(p.ObjectType) == 0 && !hasARN {
		return fmt.Errorf("Must use objectType when a full ARN is not specified: %s", p.ObjectName)
	}

	// Make sure the ARN is for a supported service
	_, ok := typeMap[objARN.Service]
	if len(p.ObjectType) == 0 && !ok {
		return fmt.Errorf("Invalid service in ARN: %s", objARN.Service)
	}

	// Make sure objectType is one we understand
	_, ok = typeMap[p.ObjectType]
	if len(p.ObjectType) != 0 && (!ok || p.ObjectType == "ssm") {
		return fmt.Errorf("Invalid objectType: %s", p.ObjectType)
	}

	// If both ARN and objectType are used make sure they agree
	if len(p.ObjectType) != 0 && hasARN && typeMap[p.ObjectType] != typeMap[objARN.Service] {
		return fmt.Errorf("objectType does not match ARN: %s", p.ObjectName)
	}

	// Can only use objectVersion or objectVersionLabel for SSM not both
	if p.GetSecretType() == SSMParameter && len(p.ObjectVersion) != 0 && len(p.ObjectVersionLabel) != 0 {
		return fmt.Errorf("ssm parameters can not specify both objectVersion and objectVersionLabel: %s", p.ObjectName)
	}

	return nil
}

// Group requested objects by secret type and return a map (keyed by secret type) of slices of requests.
//
// This function will parse the objects array specified in the
// SecretProviderClass passed on the mount request. All entries will be
// validated. The object will be grouped into slices based on GetSecretType()
// and returned in a map keyed by secret type. This is to allow batching of
// requests.
//
func NewSecretDescriptorList(objectSpec string) (desc map[SecretType][]*SecretDescriptor, e error) {

	// Unpack the SecretProviderClass mount specification
	descriptors := make([]*SecretDescriptor, 0)
	err := yaml.Unmarshal([]byte(objectSpec), &descriptors)
	if err != nil {
		return nil, fmt.Errorf("Failed to load SecretProviderClass: %+v", err)
	}

	// Validate each record and check for duplicates
	groups := make(map[SecretType][]*SecretDescriptor, 0)
	names := make(map[string]bool)
	for _, descriptor := range descriptors {

		err = descriptor.validateSecretDescriptor()
		if err != nil {
			return nil, err
		}

		// Group secrets of the same type together to allow batching requests
		sType := descriptor.GetSecretType()
		groups[sType] = append(groups[sType], descriptor)

		// Check for duplicate names
		if names[descriptor.ObjectName] {
			return nil, fmt.Errorf("Name already in use for objectName: %s", descriptor.ObjectName)
		}
		names[descriptor.ObjectName] = true

		if len(descriptor.ObjectAlias) == 0 { // Alias not used, no more checks.
			continue
		}

		// Check if the alias conflicts with an existing name
		if names[descriptor.ObjectAlias] {
			return nil, fmt.Errorf("Name already in use for objectAlias: %s", descriptor.ObjectAlias)
		}
		names[descriptor.ObjectAlias] = true

	}

	return groups, nil
}
