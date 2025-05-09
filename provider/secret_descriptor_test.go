package provider

import (
	"fmt"
	"os"
	"strings"
	"testing"
)

var singleRegion = []string{"us-west-2"}

func TestGetSecretTypeSM(t *testing.T) {
	descriptor := SecretDescriptor{
		ObjectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:/feaw",
	}

	secretType := descriptor.GetSecretType()

	if secretType != SecretsManager {
		t.Fatalf("expected type secretsmanager but got type: %s", secretType)
	}
}

func TestGetSecretTypeSSM(t *testing.T) {
	descriptor := SecretDescriptor{
		ObjectName: "arn:aws:ssm:us-west-2:123456789012:parameter/feaw",
	}

	secretType := descriptor.GetSecretType()

	if secretType != SSMParameter {
		t.Fatalf("expected type ssmparameter but got type: %s", secretType)
	}
}

func RunDescriptorValidationTest(t *testing.T, descriptor *SecretDescriptor, expectedErrorMessage string) {
	err := descriptor.validateSecretDescriptor(singleRegion)
	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

func TestNoNamePresent(t *testing.T) {
	descriptor := SecretDescriptor{}

	expectedErrorMessage := "Object name must be specified"

	RunDescriptorValidationTest(t, &descriptor, expectedErrorMessage)
}

func TestNoTypePresent(t *testing.T) {
	objectName := "arn::"

	descriptor := SecretDescriptor{
		ObjectName: objectName,
	}

	expectedErrorMessage := fmt.Sprintf("Invalid ARN format in object name: %s", objectName)
	RunDescriptorValidationTest(t, &descriptor, expectedErrorMessage)
}

func TestUnknownService(t *testing.T) {
	objectName := "arn:aws:sts:us-west-2:123456789012:parameter/feaw"

	descriptor := SecretDescriptor{
		ObjectName: objectName,
	}

	expectedErrorMessage := fmt.Sprintf("Invalid service in ARN: sts")
	RunDescriptorValidationTest(t, &descriptor, expectedErrorMessage)
}

func TestSSMWithArn(t *testing.T) {
	objectName := "arn:aws:ssm:us-west-2:123456789012:parameter/feaw"

	descriptor := SecretDescriptor{
		ObjectName: objectName,
	}

	err := descriptor.validateSecretDescriptor(singleRegion)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

}

func TestNoObjectTypeWoArn(t *testing.T) {
	objectName := "SomeSecret"

	descriptor := SecretDescriptor{
		ObjectName: objectName,
	}

	expectedErrorMessage := fmt.Sprintf("Must use objectType when a full ARN is not specified: %s", objectName)
	RunDescriptorValidationTest(t, &descriptor, expectedErrorMessage)
}

func TestInvalidObjectType(t *testing.T) {
	objectType := "sts"
	descriptor := SecretDescriptor{
		ObjectName: "SomeName",
		ObjectType: objectType,
	}

	expectedErrorMessage := fmt.Sprintf("Invalid objectType: %s", objectType)
	RunDescriptorValidationTest(t, &descriptor, expectedErrorMessage)
}

func TestSSMObjectType(t *testing.T) {
	objectType := "ssm"
	descriptor := SecretDescriptor{
		ObjectName: "SomeName",
		ObjectType: objectType,
	}

	expectedErrorMessage := fmt.Sprintf("Invalid objectType: %s", objectType)
	RunDescriptorValidationTest(t, &descriptor, expectedErrorMessage)
}

func TestObjectTypeMisMatchArn(t *testing.T) {
	objectName := "arn:aws:secretsmanager:us-west-2:123456789012:secret:/feaw"
	descriptor := SecretDescriptor{
		ObjectName: objectName,
		ObjectType: "ssmparameter",
	}

	expectedErrorMessage := fmt.Sprintf("objectType does not match ARN: %s", objectName)
	RunDescriptorValidationTest(t, &descriptor, expectedErrorMessage)
}

func TestSSMBothVersionandLabel(t *testing.T) {
	objectName := "SomeParameter"

	descriptor := SecretDescriptor{
		ObjectName:         objectName,
		ObjectVersionLabel: "SomeLabel",
		ObjectVersion:      "VersionId",
		ObjectType:         "ssmparameter",
	}

	expectedErrorMessage := fmt.Sprintf("ssm parameters can not specify both objectVersion and objectVersionLabel: %s", objectName)
	RunDescriptorValidationTest(t, &descriptor, expectedErrorMessage)
}

// Conflicting name; alias and version label not present -- should throw (case 4)
func TestConflictingNameWoAliasAndVersionLabel(t *testing.T) {
	objects :=
		`
        - objectName: secret1
          objectType: ssmparameter
        - objectName: secret1
          objectType: ssmparameter`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)
	expectedErrorMessage := fmt.Sprintf("found descriptor with duplicate object name %s, no object alias, and no version label", "secret1")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

// Conflicting name and alias; version label not present -- should throw (case 1)
func TestConflictingNameAndAliasWoVersionLabel(t *testing.T) {
	objects :=
		`
        - objectName: secret1
          objectAlias: aliasOne
          objectType: ssmparameter
        - objectName: secret1
          objectAlias: aliasOne
          objectType: ssmparameter`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)
	expectedErrorMessage := fmt.Sprintf("found descriptor with duplicate object name %s, duplicate object alias %s, and no version label", "secret1", "aliasOne")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

// Conflicting name and alias; version label present -- should throw
func TestConflictingNameAndAliasWithVersionLabel(t *testing.T) {
	objects :=
		`
        - objectName: secret1
          objectAlias: aliasOne
          objectVersionLabel: AWSCURRENT
          objectType: ssmparameter
        - objectName: secret1
          objectAlias: aliasOne
          objectVersionLabel: AWSPREVIOUS
          objectType: ssmparameter`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)
	expectedErrorMessage := fmt.Sprintf("found duplicate object alias %s", "aliasOne")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

// Conflicting name; alias present, version label not present -- should not throw
func TestConflictingNameAndNotAliasWoVersionLabel(t *testing.T) {
	objects :=
		`
        - objectName: secret1
          objectAlias: aliasOne
          objectType: ssmparameter
        - objectName: secret1
          objectAlias: aliasTwo
          objectType: ssmparameter`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)

	if err != nil {
		t.Fatalf("Expected no error, got error: %v", err)
	}
}

// Conflicting name; alias and version label present -- should not throw
func TestConflictingNameAndNotAliasWithVersionLabel(t *testing.T) {
	objects :=
		`
        - objectName: secret1
          objectAlias: aliasOne
          objectVersionLabel: AWSCURRENT
          objectType: ssmparameter
        - objectName: secret1
          objectAlias: aliasTwo
          objectVersionLabel: AWSPREVIOUS
          objectType: ssmparameter`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)

	if err != nil {
		t.Fatalf("Expected no error, got error: %v", err)
	}
}

// Conflicting name and version label; alias not present -- should throw (case 2)
func TestConflictingNameAndVersionLabelWoAlias(t *testing.T) {
	objects :=
		`
        - objectName: secret1
          objectVersionLabel: AWSCURRENT
          objectType: ssmparameter
        - objectName: secret1
          objectVersionLabel: AWSCURRENT
          objectType: ssmparameter`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)
	expectedErrorMessage := fmt.Sprintf("found descriptor with duplicate object name %s, no object alias, and duplicate version label %s", "secret1", "AWSCURRENT")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

// Conflicting name, alias, and version label -- should throw (case 3)
func TestConflictingNameAndVersionLabelAndAlias(t *testing.T) {
	objects :=
		`
        - objectName: secret1
          objectAlias: aliasOne
          objectVersionLabel: AWSCURRENT
          objectType: ssmparameter
        - objectName: secret1
          objectAlias: aliasOne
          objectVersionLabel: AWSCURRENT
          objectType: ssmparameter`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)
	expectedErrorMessage := fmt.Sprintf("found descriptor with duplicate object name %s, duplicate object alias %s, and duplicate version label %s", "secret1", "aliasOne", "AWSCURRENT")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

// Conflicting name; version label present, alias not present -- should not throw
func TestConflictingNameAndNotVersionLabelWoAlias(t *testing.T) {
	objects :=
		`
        - objectName: secret1
          objectVersionLabel: AWSCURRENT
          objectType: ssmparameter
        - objectName: secret1
          objectVersionLabel: AWSPREVIOUS
          objectType: ssmparameter`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)

	if err != nil {
		t.Fatalf("Expected no error, got error: %v", err)
	}
}

// Conflicting name; version label and alias present -- should not throw
func TestConflictingNameWithAliasAndVersionLabel(t *testing.T) {
	objects :=
		`
        - objectName: secret1
          objectAlias: aliasOne
          objectVersionLabel: AWSCURRENT
          objectType: ssmparameter
        - objectName: secret1
          objectAlias: aliasTwo
          objectVersionLabel: AWSPREVIOUS
          objectType: ssmparameter`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)

	if err != nil {
		t.Fatalf("Expected no error, got error: %v", err)
	}
}

func TestConflictingAlias(t *testing.T) {
	objects :=
		`
          - objectName: secret1
            objectType: ssmparameter
            objectAlias: aliasOne
          - objectName: secret2
            objectType: ssmparameter
            objectAlias: aliasOne`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)
	expectedErrorMessage := fmt.Sprintf("found duplicate object alias %s", "aliasOne")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

func TestConflictingAliasJMES(t *testing.T) {
	objects :=
		`
          - objectName: secret1
            objectType: ssmparameter
            objectAlias: aliasOne
          - objectName: secret2
            objectType: ssmparameter
            jmesPath:
              - path: .username
                objectAlias: aliasOne`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)
	expectedErrorMessage := fmt.Sprintf("Name already in use for objectAlias: found duplicate object alias %s in JMES path entry %s", "aliasOne", ".username")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

func TestMissingAliasJMES(t *testing.T) {
	objects :=
		`
          - objectName: secret2
            objectType: ssmparameter
            jmesPath:
              - path: .username`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)
	expectedErrorMessage := fmt.Sprintf("Object alias must be specified for JMES object")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

func TestMissingPathJMES(t *testing.T) {
	objects :=
		`
          - objectName: secret2
            objectType: ssmparameter
            jmesPath:
              - objectAlias: aliasOne`

	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)
	expectedErrorMessage := fmt.Sprintf("Path must be specified for JMES object")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

// test separation/grouping into ssm/secretsmanager with valid parameters
func TestNewDescriptorList(t *testing.T) {
	objects := `
          - objectName: secret1
            objectType: secretsmanager
          - objectName: secret2
            objectType: ssmparameter
          - objectName: secret3
            objectType: ssmparameter
            objectAlias: myParm`
	descriptorList, err := NewSecretDescriptorList("/", "_", objects, singleRegion)

	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if len(descriptorList[SSMParameter]) != 2 {
		t.Fatalf("Only expected 2 ssm objects but got %d", len(descriptorList[SSMParameter]))
	}
	if len(descriptorList[SecretsManager]) != 1 {
		t.Fatalf("Only expected 1 ssm object but got %d", len(descriptorList[SecretsManager]))
	}

	if descriptorList[SSMParameter][0].GetFileName() != "secret2" {
		t.Fatalf("Bad file name %s", descriptorList[SSMParameter][0].GetFileName())
	}
	if descriptorList[SSMParameter][1].GetFileName() != "myParm" {
		t.Fatalf("Bad file name %s", descriptorList[SSMParameter][0].GetFileName())
	}

}

// test separation/grouping into ssm/secretsmanager with valid parameters
func TestBadYaml(t *testing.T) {
	objects := `
          - objectName: secret1
            objectType: secretsmanager
          - {`
	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)

	if err == nil {
		t.Fatalf("Expected error but got none.")
	}
}

// test separation/grouping into ssm/secretsmanager with valid parameters
func TestErrorYaml(t *testing.T) {
	objects := `
          - objectName: secret1`
	_, err := NewSecretDescriptorList("/", "", objects, singleRegion)

	if err == nil {
		t.Fatalf("Expected error but got none.")
	}
}

// Validate enum strings are translated correctly
func TestEnumStrings(t *testing.T) {
	if fmt.Sprint(SSMParameter) != "ssmparameter" {
		t.Fatalf("Bad enum string %s", SSMParameter)
	}
	if fmt.Sprint(SecretsManager) != "secretsmanager" {
		t.Fatalf("Bad enum string %s", SecretsManager)
	}
}

// test separation/grouping into ssm/secretsmanager with valid parameters
func TestBadTrans(t *testing.T) {
	objects := `
          - objectName: secret1
            objectType: secretsmanager
    `
	_, err := NewSecretDescriptorList("/", "--", objects, singleRegion)

	if err == nil || !strings.Contains(err.Error(), "must be either 'False' or a single character") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

func TestGetPath(t *testing.T) {
	objects := `
        - objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:secret1"
          objectAlias: secret1
        - objectName: parm1
          objectType: ssmparameter
    `

	descriptorList, err := NewSecretDescriptorList("/mountpoint", "", objects, singleRegion)
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if len(descriptorList[SSMParameter]) != 1 || len(descriptorList[SecretsManager]) != 1 {
		t.Fatalf("Missing descriptors")
	}
	if descriptorList[SSMParameter][0].GetMountPath() != "/mountpoint/parm1" {
		t.Errorf("Bad mount path for SSM parameter")
	}
	if descriptorList[SecretsManager][0].GetMountPath() != "/mountpoint/secret1" {
		t.Errorf("Bad mount path for secret")
	}

}

func TestTraversal(t *testing.T) {
	objects := []string{
		`
        - objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:/../pathTest-abc123"
        `, `
        - objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:mypath/../../pathTest-abc123"
        `, `
        - objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:mypath/.."

        `, `
        - objectName: "../mypath"
          objectType: secretsmanager
        `, `
        - objectName: "mypath/../../param"
          objectType: secretsmanager
        `, `
        - objectName: "mypath/.."
          objectType: secretsmanager
        `, `
        - objectName: "../mypath"
          objectType: ssmparameter
        `, `
        - objectName: "mypath/../../param"
          objectType: ssmparameter
        `, `
        - objectName: "mypath/.."
          objectType: ssmparameter
        `,
	}

	for _, obj := range objects {

		_, err := NewSecretDescriptorList("/", "False", obj, singleRegion)

		if err == nil || !strings.Contains(err.Error(), "path can not contain ../") {
			t.Errorf("Expected error: path can not contain ../, got error: %v\n%v", err, obj)
		}

	}
}

func TestNotTraversal(t *testing.T) {
	objects := []string{
		`
        - objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:/..pathTest-abc123"
        `, `
        - objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:..pathTest-abc123"
        `, `
        - objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:mypath../pathTest-abc123"
        `, `
        - objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:mypath.."
        `, `
        - objectName: "/..mypath"
          objectType: ssmparameter
        `, `
        - objectName: "..mypath"
          objectType: ssmparameter
        `, `
        - objectName: "mypath../param"
          objectType: ssmparameter
        `, `
        - objectName: "mypath.."
          objectType: ssmparameter
        `,
	}

	for _, obj := range objects {

		desc, err := NewSecretDescriptorList("/", "False", obj, singleRegion)

		if len(desc[SSMParameter]) == 0 && len(desc[SecretsManager]) == 0 {
			t.Errorf("TestNotTraversal: Missing descriptor for %v", obj)
		}

		if err != nil {
			t.Errorf("Unexpected error: %v\n%v", err, obj)
		}

	}

}

// If the failoverObject exists, then the object must have an alias.
func TestFallbackObjectRequiresAlias(t *testing.T) {
	objects := `
    - objectName: "arn:aws:secretsmanager:us-west-1:123456789012:secret:secret1"
      failoverObject:
        objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:secret1"`

	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1", "us-west-2"})
	if err == nil || !strings.Contains(err.Error(), "object alias must be specified for objects with failover entries") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

// If either the main objectname or failoverObject's object name are not arns, then the objectType must be specified (failover is not ARN).
func TestFallbackNonARNStillNeedsObjectType(t *testing.T) {
	objects := `
    - objectName: "arn:aws:secretsmanager:us-west-1:123456789012:secret:secret1"
      failoverObject: {objectName: "MySecret"}
      objectAlias: test
    `
	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1", "us-west-2"})

	if err == nil || !strings.Contains(err.Error(), "Must use objectType when a full ARN is not specified") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

// If either the main objectname or failoverObject's object name are not arns, then the objectType must be specified (main objectName is not ARN).
func TestBackupArnMustBePairedWithObjectType(t *testing.T) {
	objects := `
    - objectName: "MySecret"
      objectAlias: test
      failoverObject:
         objectName: "arn:aws:secretsmanager:us-west-1:123456789012:secret:secret1"`

	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-2", "us-west-1"})

	if err == nil || !strings.Contains(err.Error(), "Must use objectType when a full ARN is not specified") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

// If the failover descriptor is an ARN, and the objectType is specified, then they must match which provider to use.
func TestBackupArnDoesNotMatchType(t *testing.T) {
	objects := `
    - objectName: "arn:aws:secretsmanager:us-west-1:123456789012:secret:secret1"
      failoverObject: {objectName: "arn:aws:bad:us-west-2:123456789012:secret:secret1"}
      objectType: "secretsmanager"
      objectAlias: test
    `
	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1", "us-west-2"})

	if err == nil || !strings.Contains(err.Error(), "objectType does not match ARN") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

// The failoverObject must be a valid service name.
func TestBackupArnInvalidType(t *testing.T) {
	objects := `
    - objectName: "arn:aws:secretsmanager:us-west-1:123456789012:secret:secret1"
      failoverObject: {objectName: "arn:aws:bad:us-west-2:123456789012:secret:secret1"}
      objectAlias: test
    `
	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1", "us-west-2"})

	if err == nil || !strings.Contains(err.Error(), "Invalid service in ARN") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

// Success case: both ARNs match.
func TestBackupArnSuccess(t *testing.T) {
	objects := `
    - objectName: "arn:aws:secretsmanager:us-west-1:123456789012:secret:secret1"
      failoverObject: {objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:secret1"}
      objectAlias: test
    `
	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1", "us-west-2"})

	if err != nil {
		t.Errorf("Unexpected error: %v", err)
	}
}

// The main regions must now match.  This main ARN is for one region, and the main region is configured for a different one.
func TestPrimaryArnRequiresRegionMatch(t *testing.T) {
	objects := `
    - objectName: "arn:aws:secretsmanager:us-west-1:123456789012:secret:secret1"
      objectAlias: test
    `
	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-2"})

	if err == nil || !strings.Contains(err.Error(), "ARN region must match region us-west-2") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

// The failover regions must now match. This failover ARN is for one region, and failover region is configured for a different one.
func TestBackupArnRequiresRegionMatch(t *testing.T) {
	objects := `
    - objectName: "arn:aws:secretsmanager:us-west-1:123456789012:secret:secret1"
      failoverObject: {objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:secret1"}
      objectAlias: test
    `
	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1", "us-east-2"})

	if err == nil || !strings.Contains(err.Error(), "ARN region must match region us-east-2") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

// If a failoverObject is given, then a failover region must be given.
func TestFallbackDataRequiresMultipleRegions(t *testing.T) {
	objects := `
    - objectName: "arn:aws:secretsmanager:us-west-1:123456789012:secret:secret1"
      failoverObject: {objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:secret1"}
      objectAlias: test
    `
	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1"})

	if err == nil || !strings.Contains(err.Error(), "failover object allowed only when failover region") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

// If using ssmparameter and a failoverObject, then using both objectVersion and objectVersionLabel is invalid
func TestObjectVersionAndLabelAreIncompatible(t *testing.T) {
	objects := `
    - objectName: "MySecret1"
      objectType: ssmparameter
      failoverObject:
        objectName:         MySecretInAnotherRegion
        objectVersion:      VersionId
        objectVersionLabel: MyLabel
      objectAlias: test
    `
	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1", "us-west-2"})

	if err == nil || !strings.Contains(err.Error(), "ssm parameters can not specify both objectVersion and objectVersionLabel") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

// Validate that the mountpoint still follows the objectAlias, even if multiple regions are defined.
func TestGetPathForMultiregion(t *testing.T) {
	objects := `
    - objectName: "MySecret1"
      objectType: ssmparameter
      failoverObject:
        objectName:         MySecretInAnotherRegion
      objectAlias: test
    `
	descriptorList, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1", "us-west-2"})
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if len(descriptorList[SSMParameter]) != 1 {
		t.Fatalf("Missing descriptors")
	}
	if descriptorList[SSMParameter][0].GetMountPath() != "/mountpoint/test" {
		t.Errorf("Bad mount path for SSM parameter")
	}

}

// A few objectVersion tests. The two must be equal.
func TestVersionIdsMustMatch(t *testing.T) {
	objects := `
    - objectName: "MySecret1"
      objectType: ssmparameter
      objectVersion:  OldVersionId
      failoverObject:
        objectName:         MySecretInAnotherRegion
        objectVersion:      ADifferentVersionId
      objectAlias: test
    `

	_, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1", "us-west-2"})

	if err == nil || !strings.Contains(err.Error(), "object versions must match between primary and failover regions") {
		t.Fatalf("Unexpected error, got %v", err)
	}
}

// Test Version Ids acceptibal if they match.
func TestVersionidsMatch(t *testing.T) {
	objects := `
    - objectName: "MySecret1"
      objectType: ssmparameter
      objectVersion:  VersionId
      failoverObject:
        objectName:         MySecretInAnotherRegion
        objectVersion:  VersionId
      objectAlias: test
    `
	descriptorList, err := NewSecretDescriptorList("/mountpoint", "", objects, []string{"us-west-1", "us-west-2"})
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}
	if len(descriptorList[SSMParameter]) != 1 {
		t.Fatalf("Missing descriptors")
	}
	if descriptorList[SSMParameter][0].GetMountPath() != "/mountpoint/test" {
		t.Errorf("Bad mount path for SSM parameter")
	}

}

// Test GetFilePermission function
func TestGetFilePermission(t *testing.T) {

	TestDescriptor := func(filePermission string) SecretDescriptor {
		return SecretDescriptor{
			ObjectType:     "SecretsManager",
			FilePermission: filePermission,
		}
	}

	t.Run("DefaultFilePermission", func(t *testing.T) {
		descriptor := TestDescriptor("")
		got := descriptor.GetFilePermission()
		want := os.FileMode(0644)
		if got != want {
			t.Errorf("got: %v != want: %v", got, want)
		}
	})

	t.Run("CustomFilePermission", func(t *testing.T) {
		descriptor := TestDescriptor("0600")
		got := descriptor.GetFilePermission()
		want := os.FileMode(0600)
		if got != want {
			t.Errorf("got: %v != want: %v", got, want)
		}
	})
}

// Test validateFilePermission function
func TestValidateFilePermission(t *testing.T) {
	descriptor := SecretDescriptor{}

	checkNoError := func(t testing.TB, got error) {
		t.Helper()

		if got != nil {
			t.Errorf("Unexpected error: %v", got)
		}
	}

	checkErrorMessage := func(t testing.TB, got error, want string) {
		t.Helper()

		if got == nil {
			t.Errorf("No error when expected error: %v ", want)
		}

		if got.Error() != want {
			t.Errorf("got: %v want: %v", got, want)
		}
	}

	expectedErrorMessage := func(filePermission string) string {
		return fmt.Sprintf("Invalid File Permission: %s", filePermission)
	}

	t.Run("EmptyFilePermission", func(t *testing.T) {
		got := descriptor.validateFilePermission("")
		checkNoError(t, got)
	})

	t.Run("CorrectOctalFilePermission", func(t *testing.T) {
		got := descriptor.validateFilePermission("0600")
		checkNoError(t, got)
	})

	t.Run("InvalidFilePermission", func(t *testing.T) {
		got := descriptor.validateFilePermission("abc9")
		checkErrorMessage(t, got, expectedErrorMessage("abc9"))
	})

	t.Run("ShortFilePermission", func(t *testing.T) {
		got := descriptor.validateFilePermission("000")
		checkErrorMessage(t, got, expectedErrorMessage("000"))
	})

	t.Run("LongFilePermission", func(t *testing.T) {
		got := descriptor.validateFilePermission("00000")
		checkErrorMessage(t, got, expectedErrorMessage("00000"))
	})
}

// Test getJmesSecretDescriptor function
func TestGetJmesEntrySecretDescriptor(t *testing.T) {

	TestDescriptor := func(filePermission string) SecretDescriptor {
		return SecretDescriptor{
			ObjectType:     "SecretsManager",
			FilePermission: filePermission,
		}
	}

	TestJmesPath := func(filePermission string) JMESPathEntry {
		return JMESPathEntry{
			FilePermission: filePermission,
		}
	}

	checkPermissions := func(t testing.TB, got *SecretDescriptor, want string) {
		t.Helper()
		if got.FilePermission != want {
			t.Errorf("got: %v want: %v", got.FilePermission, want)
		}
	}

	t.Run("EmptyFilePermission", func(t *testing.T) {
		descriptor := TestDescriptor("")
		jmesPath := TestJmesPath("")
		got := descriptor.getJmesEntrySecretDescriptor(&jmesPath)
		checkPermissions(t, &got, "")
	})

	t.Run("InheritFromParent", func(t *testing.T) {
		descriptor := TestDescriptor("0600")
		jmesPath := TestJmesPath("")
		got := descriptor.getJmesEntrySecretDescriptor(&jmesPath)
		checkPermissions(t, &got, descriptor.FilePermission)
	})

	t.Run("OverrideParent", func(t *testing.T) {
		descriptor := TestDescriptor("0600")
		jmesPath := TestJmesPath("0777")
		got := descriptor.getJmesEntrySecretDescriptor(&jmesPath)
		checkPermissions(t, &got, jmesPath.FilePermission)
	})
}

// Test the validatedescriptor function calls validate file permission
func TestValidateDescriptorFilePermission(t *testing.T) {

	TestDescriptor := func(descriptorPermission string, jmesPermission string) SecretDescriptor {
		return SecretDescriptor{
			ObjectName:     "foo",
			ObjectType:     "secretsmanager",
			FilePermission: descriptorPermission,
			JMESPath: []JMESPathEntry{
				{
					Path:           "bar",
					ObjectAlias:    "foobar",
					FilePermission: jmesPermission,
				},
			},
		}
	}

	expectedErrorMessage := func(filePermission string) string {
		return fmt.Sprintf("Invalid File Permission: %s", filePermission)
	}

	t.Run("DescriptorValidPermission", func(t *testing.T) {
		descriptor := TestDescriptor("0600", "0700")
		got := descriptor.validateSecretDescriptor(singleRegion)
		if got != nil {
			t.Errorf("Unexpected Error %v", got)
		}
	})

	t.Run("DescriptorInvalidPermission", func(t *testing.T) {
		descriptor := TestDescriptor("abcd", "")
		got := descriptor.validateSecretDescriptor(singleRegion)
		want := expectedErrorMessage("abcd")
		if got == nil || got.Error() != want {
			t.Errorf("got: %v want: %v", got, want)
		}
	})

	t.Run("DescriptorInvalidjmesPermission", func(t *testing.T) {
		descriptor := TestDescriptor("", "efgh")
		got := descriptor.validateSecretDescriptor(singleRegion)
		want := expectedErrorMessage("efgh")
		if got == nil || got.Error() != want {
			t.Errorf("got: %v want: %v", got, want)
		}
	})
}
