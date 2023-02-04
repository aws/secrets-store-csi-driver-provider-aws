package provider

import (
	"fmt"

	"sigs.k8s.io/yaml"
)

// An individual record from the mount request indicating the secret to be
// fetched and mounted.
type GlobalParams struct {

	// Name of the secret
	Descriptors []*SecretDescriptor `json:"objects"`

	// Optional base file name in which to store the secret (use ObjectName if nil).
	JoinName string `json:"joinName"`
	
	//Grouped descriptors
	DescriptorsGroups map[SecretType][]*SecretDescriptor `json:-`
}

// Returns the file name where the secrets are to be written.
//
// Uses either the ObjectName or ObjectAlias to construct the file name.
//
func (p *GlobalParams) AppendJoinSecret(values []*SecretValue) (jointValues []*SecretValue) {
	if p.JoinName != "" {
		secretsMap := make(map [string]*SecretValue)
		for _, secVal := range values {
			if secVal.Descriptor.isTemplated {
				secretsMap[secVal.Descriptor.ObjectAlias]= secVal
			}
		}
	
		jointSecret := ""
		var first *SecretDescriptor
		for _, secret := range values {
		 	if secret.Descriptor.isTemplated {
		 		jointSecret = jointSecret + string(secretsMap[secret.Descriptor.ObjectAlias].Value[:])
		 		if first == nil {
		 			first= &secret.Descriptor
		 		}
		 	}
		}
		
		sd := SecretDescriptor{
			ObjectAlias: p.JoinName,
			ObjectType:  first.getObjectType(),
			translate:   first.translate,
			mountDir:    first.mountDir,
		}
		
		sv := SecretValue{
			Value:      []byte(jointSecret),
			Descriptor: sd,
		}
		
		values= append(values, &sv)
	
		cleanValues := make([]*SecretValue, len(values) - len(secretsMap))
		i := 0
		for _, secVal := range values {
			if !secVal.Descriptor.isTemplated {
				cleanValues[i] = secVal
				i++
			}
		}
		
		values = cleanValues
	}

	return values
}

func (p *GlobalParams) GetDescriptors() (map[SecretType][]*SecretDescriptor) {
	return p.DescriptorsGroups
}



// Group requested objects by secret type and return a map (keyed by secret type) of slices of requests.
//
// This function will parse the objects array specified in the
// SecretProviderClass passed on the mount request. All entries will be
// validated. The object will be grouped into slices based on GetSecretType()
// and returned in a map keyed by secret type. This is to allow batching of
// requests.
//
func NewGlobalParams(mountDir, translate, objectSpec string, regions []string) (
	desc *GlobalParams,
	e error,
) {
	// Unpack the SecretProviderClass mount specification
	globalParams := GlobalParams{}
	err := yaml.Unmarshal([]byte(objectSpec), &globalParams)
	if err != nil {
		return nil, fmt.Errorf("Failed to load SecretProviderClass: %+v", err)
	}
	
	groups, err := NewSecretDescriptorList(mountDir, translate, globalParams.Descriptors, regions)
	if err != nil {
		return nil, err
	}
	
	globalParams.DescriptorsGroups= groups
	
	return &globalParams, nil
}
