package provider

import (
	"fmt"
	"testing"
)

var TEST_OBJECT_NAME = "jsonObject"

func RunGetJsonSecretTest(t *testing.T, jsonContent string, path string, objectAlias string,
	objectEncoding string, expectedErrorMessage string) {

	jmesPath := []JMESPathEntry{
		{
			Path:           path,
			ObjectAlias:    objectAlias,
			ObjectEncoding: objectEncoding,
		},
	}

	descriptor := SecretDescriptor{
		ObjectName: TEST_OBJECT_NAME,
		JMESPath:   jmesPath,
		ObjectType: "secretsmanager",
	}

	secretValue := SecretValue{
		Value:      []byte(jsonContent),
		Descriptor: descriptor,
	}

	values, err := secretValue.getJsonSecrets()

	// If we expect no error but got one
	if expectedErrorMessage == "" && err != nil {
		t.Fatalf("Expected no error, but got: %v", err)
	}

	// If we expect an error
	if expectedErrorMessage != "" {
		if err == nil {
			t.Fatalf("Expected error: %s, but got no error", expectedErrorMessage)
		}

		if err.Error() != expectedErrorMessage {
			t.Fatalf("Expected error: %s, got error: %v", expectedErrorMessage, err)
		}
		return
	}

	// For the base64 decoding test, verify the result
	if objectEncoding == "base64" && len(values) > 0 {
		decodedValue := string(values[0].Value)
		expected := "Hello, World!"
		if decodedValue != expected {
			t.Fatalf("Expected decoded value '%s', got '%s'", expected, decodedValue)
		}
	}
}

func TestNotValidJson(t *testing.T) {

	path := ".username"
	objectAlias := "test"
	jsonContent := "NotValidJson"
	expectedErrorMessage := fmt.Sprintf("Invalid JSON used with jmesPath in secret: %s.", TEST_OBJECT_NAME)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, "", expectedErrorMessage)
}

func TestJMESPathPointsToInvalidObject(t *testing.T) {

	jsonContent := `{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}`
	path := "testpath"
	objectAlias := "testAlias"
	expectedErrorMessage := fmt.Sprintf("JMES Path - %s for object alias - %s does not point to a valid object.", path, objectAlias)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, "", expectedErrorMessage)
}

func TestInvalidJMESPath(t *testing.T) {

	jsonContent := `{"username": "ParameterStoreUser", "password": "PasswordForParameterStore"}`
	path := ".testpath"
	objectAlias := "testAlias"
	expectedErrorMessage := fmt.Sprintf("Invalid JMES Path: %s.", path)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, "", expectedErrorMessage)
}

func TestInvalidJMESResultType(t *testing.T) {

	jsonContent := `{"username": 3}`
	path := "username"
	objectAlias := "testAlias"
	expectedErrorMessage := fmt.Sprintf("Invalid JMES search result type for path:%s. Only string is allowed.", path)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, "", expectedErrorMessage)
}

func TestBase64DecodeJSONValue(t *testing.T) {
	// Base64 encoding of "Hello, World!"
	base64Value := "SGVsbG8sIFdvcmxkIQ=="
	jsonContent := fmt.Sprintf(`{"encodedValue": "%s"}`, base64Value)
	path := "encodedValue"
	objectAlias := "decoded-value"

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, "base64", "")
}

func TestBase64DecodeJSONValueInvalidBase64(t *testing.T) {
	invalidBase64 := "InvalidBase64!!!"
	jsonContent := fmt.Sprintf(`{"encodedValue": "%s"}`, invalidBase64)
	path := "encodedValue"
	objectAlias := "decoded-value"
	expectedErrorMessage := fmt.Sprintf("failed to decode base64 value for JMES path %s in secret %s: illegal base64 data at input byte 13",
		path, TEST_OBJECT_NAME)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, "base64", expectedErrorMessage)
}

func TestUnsupportedEncodingType(t *testing.T) {
	value := "some-value"
	jsonContent := fmt.Sprintf(`{"encodedValue": "%s"}`, value)
	path := "encodedValue"
	objectAlias := "encoded-value"
	expectedErrorMessage := fmt.Sprintf("unsupported encoding type %s for JMES path %s in secret %s",
		"unknown", path, TEST_OBJECT_NAME)

	RunGetJsonSecretTest(t, jsonContent, path, objectAlias, "unknown", expectedErrorMessage)
}

func TestNoEncoding(t *testing.T) {
	// Base64 encoding of "Hello, World!"
	base64Value := "SGVsbG8sIFdvcmxkIQ=="
	jsonContent := fmt.Sprintf(`{"encodedValue": "%s"}`, base64Value)
	path := "encodedValue"
	objectAlias := "non-decoded-value"

	jmesPath := []JMESPathEntry{
		{
			Path:        path,
			ObjectAlias: objectAlias,
			// No encoding specified
		},
	}

	descriptor := SecretDescriptor{
		ObjectName: TEST_OBJECT_NAME,
		ObjectType: "secretsmanager",
		JMESPath:   jmesPath,
	}

	secretValue := SecretValue{
		Value:      []byte(jsonContent),
		Descriptor: descriptor,
	}

	values, err := secretValue.getJsonSecrets()
	if err != nil {
		t.Fatalf("Unexpected error: %v", err)
	}

	if len(values) != 1 {
		t.Fatalf("Expected 1 value, got %d", len(values))
	}

	nonDecodedValue := string(values[0].Value)
	if nonDecodedValue != base64Value {
		t.Fatalf("Expected '%s', got '%s'", base64Value, nonDecodedValue)
	}
}
