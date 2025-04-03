package provider

import (
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/aws/aws-sdk-go/aws/arn"
	"sigs.k8s.io/yaml"
)

// An RE pattern to check for bad paths
var badPathRE = regexp.MustCompile("(/\\.\\./)|(^\\.\\./)|(/\\.\\.$)")

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

	// Optional array to specify what json key value pairs to extract from a secret and mount as individual secrets
	JMESPath []JMESPathEntry `json:"jmesPath"`

	// Optional failover object
	FailoverObject FailoverObjectEntry `json:"failoverObject"`

	// Path translation character (not part of YAML spec).
	translate string `json:"-"`

	// Mount point directory (not part of YAML spec).
	mountDir string `json:"-"`
}

// Slice of the above type used for validation in NewSecretDescriptorList
type SecretDescriptorSlice struct {
	ObjectAlias string `json:"objectAlias"`

	ObjectVersionLabel string `json:"objectVersionLabel"`
}

// An individual json key value pair to mount
type JMESPathEntry struct {
	//JMES path to use for retrieval
	Path string `json:"path"`

	//File name in which to store the secret in.
	ObjectAlias string `json:"objectAlias"`
}

// An individual json key value pair to mount
type FailoverObjectEntry struct {
	// Optional name of the failover secret
	ObjectName string `json:"objectName"`

	// Optional version id of the secret (default to latest).
	ObjectVersion string `json:"objectVersion"`

	// Optional version/stage label of the secret (defaults to latest).
	ObjectVersionLabel string `json:"objectVersionLabel"`
}

// Enum of supported secret types
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
func (p *SecretDescriptor) GetFileName() (path string) {
	fileName := p.ObjectName
	if len(p.ObjectAlias) != 0 {
		fileName = p.ObjectAlias
	}

	// Translate slashes to underscore if required.
	if len(p.translate) != 0 {
		fileName = strings.ReplaceAll(fileName, string(os.PathSeparator), p.translate)
	} else {
		fileName = strings.TrimLeft(fileName, string(os.PathSeparator)) // Strip leading slash
	}

	return fileName
}

// Return the mount point directory
//
// Return the mount point directory pass in by the driver in the mount request.
func (p *SecretDescriptor) GetMountDir() string {
	return p.mountDir
}

// Get the full path name (mount point + file) of the file where the seret is stored.
//
// Returns a path name composed of the mount point and the file name.
func (p *SecretDescriptor) GetMountPath() string {
	return filepath.Join(p.GetMountDir(), p.GetFileName())
}

// Return the object type (ssmparameter, secretsmanager, or ssm)
func (p *SecretDescriptor) getObjectType() (otype string) {
	oType := p.ObjectType
	if len(oType) == 0 {
		oType = strings.Split(p.ObjectName, ":")[2] // Other checks guarantee ARN
	}
	return oType
}

// Returns the secret type (ssmparameter or secretsmanager).
//
// If the ObjectType is not specified, a full ARN must be present in the
// ObjectName so this method pulls the type from the ARN when ObjectType is
// not specified.
func (p *SecretDescriptor) GetSecretType() (stype SecretType) {

	// If no objectType, use ARN (but convert ssm to ssmparameter). Note that
	// SSM does not actually allow ARNs but we convert anyway for other checks.
	sType := p.getObjectType()

	return typeMap[sType]
}

// Return a descriptor for a jmes object entry within the secret
func (p *SecretDescriptor) getJmesEntrySecretDescriptor(j *JMESPathEntry) (d SecretDescriptor) {
	return SecretDescriptor{
		ObjectAlias: j.ObjectAlias,
		ObjectType:  p.getObjectType(),
		translate:   p.translate,
		mountDir:    p.mountDir,
	}
}

// Returns the secret name for the current descriptor.
//
// The current secret name will resolve to the ObjectName if not in failover,
//
//	and will resolve the the backup ARN if in failover.
func (p *SecretDescriptor) GetSecretName(useFailoverRegion bool) (secretName string) {
	if len(p.FailoverObject.ObjectName) > 0 && useFailoverRegion {
		return p.FailoverObject.ObjectName
	}
	return p.ObjectName
}

// Return the ObjectVersionLabel
func (p *SecretDescriptor) GetObjectVersionLabel(useFailoverRegion bool) (secretName string) {
	if len(p.FailoverObject.ObjectVersionLabel) > 0 && useFailoverRegion {
		return p.FailoverObject.ObjectVersionLabel
	}
	return p.ObjectVersionLabel
}

// Return the ObjectVersion
func (p *SecretDescriptor) GetObjectVersion(useFailoverRegion bool) (secretName string) {
	if len(p.FailoverObject.ObjectVersion) > 0 && useFailoverRegion {
		return p.FailoverObject.ObjectVersion
	}
	return p.ObjectVersion
}

// Private helper to validate the contents of SecretDescriptor.
//
// This method is used to validate input before it is used by the rest of the
// plugin.
func (p *SecretDescriptor) validateSecretDescriptor(regions []string) error {

	if len(p.ObjectName) == 0 {
		return fmt.Errorf("Object name must be specified")
	}

	err := p.validateObjectName(p.ObjectName, p.ObjectType, regions[0])
	if err != nil {
		return err
	}

	// Can only use objectVersion or objectVersionLabel for SSM not both
	if p.GetSecretType() == SSMParameter && len(p.ObjectVersion) != 0 && len(p.ObjectVersionLabel) != 0 {
		return fmt.Errorf("ssm parameters can not specify both objectVersion and objectVersionLabel: %s", p.ObjectName)
	}

	// Do not allow ../ in a path when translation is turned off
	if badPathRE.MatchString(p.GetFileName()) {
		return fmt.Errorf("path can not contain ../: %s", p.ObjectName)
	}

	//ensure each jmesPath entry has a path and an objectalias
	for _, jmesPathEntry := range p.JMESPath {
		if len(jmesPathEntry.Path) == 0 {
			return fmt.Errorf("Path must be specified for JMES object")
		}

		if len(jmesPathEntry.ObjectAlias) == 0 {
			return fmt.Errorf("Object alias must be specified for JMES object")
		}
	}

	if len(p.FailoverObject.ObjectName) > 0 {
		// Backup arns require object alias to be set.
		if len(p.ObjectAlias) == 0 {
			return fmt.Errorf("object alias must be specified for objects with failover entries: %s", p.ObjectName)
		}

		// Our regions must exist
		if len(regions) < 2 {
			return fmt.Errorf("failover object allowed only when failover region is defined: %s", p.ObjectName)
		}

		err := p.validateObjectName(p.FailoverObject.ObjectName, p.ObjectType, regions[1])
		if err != nil {
			return err
		}

		// Can only use objectVersion or objectVersionLabel for SSM not both
		if p.GetSecretType() == SSMParameter && len(p.FailoverObject.ObjectVersion) != 0 && len(p.FailoverObject.ObjectVersionLabel) != 0 {
			return fmt.Errorf("ssm parameters can not specify both objectVersion and objectVersionLabel: %s", p.ObjectName)
		}

		if p.FailoverObject.ObjectVersion != p.ObjectVersion {
			return fmt.Errorf("object versions must match between primary and failover regions: %s", p.ObjectName)
		}
	}

	return nil
}

// Private helper to validate an objectname.
//
// This function validates the objectname string, and makes sure it matches the
//
//	corresponding 'objectType' and 'region'.
func (p *SecretDescriptor) validateObjectName(objectName string, objectType string, region string) (err error) {
	var objARN arn.ARN

	// Validate if ARNs
	hasARN := strings.HasPrefix(objectName, "arn:")
	if hasARN {
		objARN, err = arn.Parse(objectName)
		if err != nil {
			return fmt.Errorf("Invalid ARN format in object name: %s", objectName)
		}
	}

	// If has an ARN, validate that it matches the primary region
	if hasARN && objARN.Region != region {
		return fmt.Errorf("ARN region must match region %s: %s", region, objectName)
	}

	// Make sure either objectType is used or a full ARN is specified
	if len(objectType) == 0 && !hasARN {
		return fmt.Errorf("Must use objectType when a full ARN is not specified: %s", objectName)
	}

	// Make sure the ARN is for a supported service
	_, ok := typeMap[objARN.Service]
	if len(objectType) == 0 && !ok {
		return fmt.Errorf("Invalid service in ARN: %s", objARN.Service)
	}

	// Make sure objectType is one we understand
	_, ok = typeMap[objectType]
	if len(objectType) != 0 && (!ok || objectType == "ssm") {
		return fmt.Errorf("Invalid objectType: %s", objectType)
	}

	// If both ARN and objectType are used make sure they agree
	if len(objectType) != 0 && hasARN && typeMap[objectType] != typeMap[objARN.Service] {
		return fmt.Errorf("objectType does not match ARN: %s", objectName)
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
func NewSecretDescriptorList(mountDir, translate, objectSpec string, regions []string) (
	desc map[SecretType][]*SecretDescriptor,
	e error,
) {

	// See if we should substitite underscore for slash
	if len(translate) == 0 {
		translate = "_" // Use default
	} else if strings.ToLower(translate) == "false" {
		translate = "" // Turn it off.
	} else if len(translate) != 1 {
		return nil, fmt.Errorf("pathTranslation must be either 'False' or a single character string")
	}

	// Unpack the SecretProviderClass mount specification
	descriptors := make([]*SecretDescriptor, 0)
	err := yaml.Unmarshal([]byte(objectSpec), &descriptors)
	if err != nil {
		return nil, fmt.Errorf("Failed to load SecretProviderClass: %+v", err)
	}

	// Validate each record and check for duplicates
	groups := make(map[SecretType][]*SecretDescriptor, 0)
	seenNames := make(map[string]SecretDescriptorSlice)
	seenAliases := make(map[string]bool)
	for _, descriptor := range descriptors {

		descriptor.translate = translate
		descriptor.mountDir = mountDir
		err = descriptor.validateSecretDescriptor(regions)
		if err != nil {
			return nil, err
		}

		// Group secrets of the same type together to allow batching requests
		sType := descriptor.GetSecretType()
		groups[sType] = append(groups[sType], descriptor)

		// We iterate over the descriptors, checking each one for duplicates and then adding it to the seenNames map.
		// There are 4 cases in which a validation error is thrown when a descriptor with a duplicate object name is found:
		// -------------------------------------------
		// | # | OBJECT ALIAS | OBJECT VERSION LABEL |
		// |---|--------------|----------------------|
		// | 1 | duplicate    | empty                |
		// | 2 | empty        | duplicate            |
		// | 3 | duplicate    | duplicate            |
		// | 4 | empty        | empty                |
		// -------------------------------------------
		found, ok := seenNames[descriptor.ObjectName]
		if ok {
			descHasAlias := descriptor.ObjectAlias != ""
			foundHasAlias := found.ObjectAlias != ""
			descHasVersionLabel := descriptor.ObjectVersionLabel != ""
			foundHasVersionLabel := found.ObjectVersionLabel != ""

			errorPrefix := fmt.Errorf("found descriptor with duplicate object name %s", descriptor.ObjectName)

			// Case 1
			if descHasAlias && foundHasAlias && !descHasVersionLabel && !foundHasVersionLabel &&
				descriptor.ObjectAlias == found.ObjectAlias {
				return nil, fmt.Errorf("%s, duplicate object alias %s, and no version label",
					errorPrefix, descriptor.ObjectAlias)
			}

			// Case 2
			if !descHasAlias && !foundHasAlias && descHasVersionLabel && foundHasVersionLabel &&
				descriptor.ObjectVersionLabel == found.ObjectVersionLabel {
				return nil, fmt.Errorf("%s, no object alias, and duplicate version label %s",
					errorPrefix, descriptor.ObjectVersionLabel)
			}

			// Case 3
			if descHasAlias && foundHasAlias && descHasVersionLabel && foundHasVersionLabel &&
				descriptor.ObjectAlias == found.ObjectAlias &&
				descriptor.ObjectVersionLabel == found.ObjectVersionLabel {
				return nil, fmt.Errorf("%s, duplicate object alias %s, and duplicate version label %s",
					errorPrefix, descriptor.ObjectAlias, descriptor.ObjectVersionLabel)
			}

			// Case 4
			if !descHasAlias && !foundHasAlias && !descHasVersionLabel && !foundHasVersionLabel {
				return nil, fmt.Errorf("%s, no object alias, and no version label", errorPrefix)
			}
		}
		// Add the descriptor to the seenNames map after validation
		seenNames[descriptor.ObjectName] = SecretDescriptorSlice{
			ObjectAlias:        descriptor.ObjectAlias,
			ObjectVersionLabel: descriptor.ObjectVersionLabel,
		}

		if seenAliases[descriptor.ObjectAlias] {
			return nil, fmt.Errorf("found duplicate object alias %s", descriptor.ObjectAlias)
		}
		// Add the object alias to the seenAliases map for use in JMES path validation below
		if descriptor.ObjectAlias != "" {
			seenAliases[descriptor.ObjectAlias] = true
		}

		if len(descriptor.JMESPath) == 0 { //jmesPath not used. No more checks
			continue
		}

		for _, jmesPathEntry := range descriptor.JMESPath {
			if seenAliases[jmesPathEntry.ObjectAlias] {
				return nil, fmt.Errorf("Name already in use for objectAlias: found duplicate object alias %s in JMES path entry %s", jmesPathEntry.ObjectAlias, jmesPathEntry.Path)
			}
			seenAliases[jmesPathEntry.ObjectAlias] = true
		}

	}

	return groups, nil
}
