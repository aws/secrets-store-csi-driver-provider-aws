package provider

import (
	"fmt"
	"testing"
)

var TEST_OBJECT_NAME = "jsonObject"

func RunGetJsonSecretTest(t *testing.T, jsonContent string, path string, objectAlias string, expectedErrorMessage string) {
	jmesPath := []JMESPathEntry{
		{
			Path:        path,
			ObjectAlias: objectAlias,
		},
	}

	descriptor := SecretDescriptor{
		ObjectName: TEST_OBJECT_NAME,
		JMESPath:   jmesPath,
	}

	secretValue := SecretValue{
		Value:      []byte(jsonContent),
		Descriptor: descriptor,
	}

	_, err := secretValue.getJsonSecrets()

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}
func TestNotValidJson(t *testing.T) {

	path := ".username"
	objectAlias := "test"
	jsonContent := "NotValidJson"
	expectedErrorMessage := fmt.Sprintf("Invalid JSON used with jmesPath in secret: %s.", TEST_OBJECT_NAME)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}

func TestJMESPathPointsToInvalidObject(t *testing.T) {

	jsonContent := `{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}`
	path := "testpath"
	objectAlias := "testAlias"
	expectedErrorMessage := fmt.Sprintf("JMES Path - %s for object alias - %s does not point to a valid object.", path, objectAlias)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}

func TestInvalidJMESPath(t *testing.T) {

	jsonContent := `{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}`
	path := ".testpath"
	objectAlias := "testAlias"
	expectedErrorMessage := fmt.Sprintf("Invalid JMES Path: %s.", path)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}

func TestInvalidJMESResultType(t *testing.T) {

	jsonContent := `{"username": 3}`
	path := "username"
	objectAlias := "testAlias"
	expectedErrorMessage := fmt.Sprintf("Invalid JMES search result type for path:%s. Only string is allowed.", path)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}

func RunGetTemplatedSecrets(t *testing.T, jsonContent string, objectTemplate string) (*SecretValue, error) {
	descriptor := SecretDescriptor{
		ObjectName: TEST_OBJECT_NAME,
		ObjectTemplate:  objectTemplate,
	}

	secretValue := SecretValue{
		Value:      []byte(jsonContent),
		Descriptor: descriptor,
	}

	secrets, err := secretValue.getTemplatedSecrets()

	if err != nil {
		return nil, err
	}

	return secrets, nil
}
func TestSecretsTemplateValidJSON(t *testing.T) {
	jsonContent := `{"username": 3, "password": "abc"}`
	template := `
	{{ range $k, $v := . }}export {{ $k }}={{ $v }}
	{{ end }}`
	expectedResult := `
	export password=abc
	export username=3
	`
	secrets, err := RunGetTemplatedSecrets(t, jsonContent, template)
	result := string(secrets.Value)
	if err != nil {
		t.Fatalf("Failed during template execution %v", err)
	}

	if result != expectedResult {
		t.Fatalf("Templated result is not correct\n got: %s\n want: %s", result, expectedResult )
	}
}

func TestSecretsTemplateInvalidJSON(t *testing.T) {
	jsonContent := `{"username": 3`
	template := `
	{{ range $k, $v := . }}export {{ $k }}={{ $v }}
	{{ end }}`
	expectedErrorMessage := fmt.Sprintf("Invalid JSON used with template in secret: %s", TEST_OBJECT_NAME)
	_, err := RunGetTemplatedSecrets(t, jsonContent, template)

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}

func TestSecretsTemplateInvalidTemplate(t *testing.T) {
	jsonContent := `{"username": 3}`
	template := `
	{ range $k, $v := . }}export {{ $k }}={{ $v }}
	{{ end }}`
	expectedErrorMessage := fmt.Sprintf("Invalid template %s", template)
	_, err := RunGetTemplatedSecrets(t, jsonContent, template)

	if err == nil || err.Error() != expectedErrorMessage {
		t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
	}
}
