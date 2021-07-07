package provider

import (
	"fmt"
	"strings"
	"testing"
)

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
	err := descriptor.validateSecretDescriptor()
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

	err := descriptor.validateSecretDescriptor()
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

func TestConflictingName(t *testing.T) {
	objects :=
		`
        - objectName: secret1
          objectType: ssmparameter
        - objectName: secret1
          objectType: ssmparameter`

	_, err := NewSecretDescriptorList("/", "", objects)
	expectedErrorMessage := fmt.Sprintf("Name already in use for objectName: %s", "secret1")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
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

	_, err := NewSecretDescriptorList("/", "", objects)
	expectedErrorMessage := fmt.Sprintf("Name already in use for objectAlias: %s", "aliasOne")

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

	_, err := NewSecretDescriptorList("/", "", objects)
	expectedErrorMessage := fmt.Sprintf("Name already in use for objectAlias: %s", "aliasOne")

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

	_, err := NewSecretDescriptorList("/", "", objects)
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

	_, err := NewSecretDescriptorList("/", "", objects)
	expectedErrorMessage := fmt.Sprintf("Path must be specified for JMES object")

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

//test separation/grouping into ssm/secretsmanager with valid parameters
func TestNewDescriptorList(t *testing.T) {
	objects := `
          - objectName: secret1
            objectType: secretsmanager
          - objectName: secret2
            objectType: ssmparameter
          - objectName: secret3
            objectType: ssmparameter
            objectAlias: myParm`
	descriptorList, err := NewSecretDescriptorList("/", "_", objects)

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

//test separation/grouping into ssm/secretsmanager with valid parameters
func TestBadYaml(t *testing.T) {
	objects := `
          - objectName: secret1
            objectType: secretsmanager
          - {`
	_, err := NewSecretDescriptorList("/", "", objects)

	if err == nil {
		t.Fatalf("Expected error but got none.")
	}
}

//test separation/grouping into ssm/secretsmanager with valid parameters
func TestErrorYaml(t *testing.T) {
	objects := `
          - objectName: secret1`
	_, err := NewSecretDescriptorList("/", "", objects)

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

//test separation/grouping into ssm/secretsmanager with valid parameters
func TestBadTrans(t *testing.T) {
	objects := `
          - objectName: secret1
            objectType: secretsmanager
    `
	_, err := NewSecretDescriptorList("/", "--", objects)

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

	descriptorList, err := NewSecretDescriptorList("/mountpoint", "", objects)
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

		_, err := NewSecretDescriptorList("/", "False", obj)

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

		desc, err := NewSecretDescriptorList("/", "False", obj)

		if len(desc[SSMParameter]) == 0 && len(desc[SecretsManager]) == 0 {
			t.Errorf("TestNotTraversal: Missing descriptor for %v", obj)
		}

		if err != nil {
			t.Errorf("Unexpected error: %v\n%v", err, obj)
		}

	}
}
