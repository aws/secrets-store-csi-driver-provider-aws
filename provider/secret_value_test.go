package provider

import (
	"strings"
	"testing"
)

var TEST_OBJECT_NAME = "jsonObject"

func RunGetJsonSecretTest(t *testing.T, jsonContent string, path string, objectAlias string, expectedErrorSubstring string) {
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

	if err == nil || !strings.Contains(err.Error(), expectedErrorSubstring) {
		t.Fatalf("Expected error containing %q, got error: %v", expectedErrorSubstring, err)
	}
}
func TestNotValidJson(t *testing.T) {

	path := ".username"
	objectAlias := "test"
	jsonContent := "NotValidJson"
	expectedErrorMessage := `Failed to parse secret "jsonObject" as JSON for JMESPath processing:`

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}

func TestJMESPathPointsToInvalidObject(t *testing.T) {

	jsonContent := `{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}`
	path := "testpath"
	objectAlias := "testAlias"
	expectedErrorMessage := `JMESPath "testpath" for object alias "testAlias" was not found in secret "jsonObject"`

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}

func TestInvalidJMESPath(t *testing.T) {

	jsonContent := `{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}`
	path := ".testpath"
	objectAlias := "testAlias"
	expectedErrorMessage := `Invalid JMESPath ".testpath" for object alias "testAlias" in secret "jsonObject":`

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}

func TestInvalidJMESResultType(t *testing.T) {

	jsonContent := `{"username": 3}`
	path := "username"
	objectAlias := "testAlias"
	expectedErrorMessage := `JMESPath "username" for object alias "testAlias" in secret "jsonObject" returned a non-string value. Only string values are supported`

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}
