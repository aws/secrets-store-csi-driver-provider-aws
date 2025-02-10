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
	expectedErrorMessage := fmt.Sprintf("invalid JSON used with jmesPath in secret: %s", TEST_OBJECT_NAME)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}

func TestJMESPathPointsToInvalidObject(t *testing.T) {

	jsonContent := `{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}`
	path := "testpath"
	objectAlias := "testAlias"
	expectedErrorMessage := fmt.Sprintf("JMES Path - %s for object alias - %s does not point to a valid object", path, objectAlias)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}

func TestInvalidJMESPath(t *testing.T) {

	jsonContent := `{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}`
	path := ".testpath"
	objectAlias := "testAlias"
	expectedErrorMessage := fmt.Sprintf("invalid JMES Path: %s", path)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}

func TestInvalidJMESResultType(t *testing.T) {

	jsonContent := `{"username": 3}`
	path := "username"
	objectAlias := "testAlias"
	expectedErrorMessage := fmt.Sprintf("invalid JMES search result type for path:%s. Only string is allowed", path)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, expectedErrorMessage)
}
