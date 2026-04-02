package provider

import (
	"encoding/json"
	"testing"

	"github.com/jmespath/go-jmespath"
)

func FuzzGetJsonSecrets(f *testing.F) {
	f.Add(`{"username": "testuser", "password": "testpass"}`, "username", "user")
	f.Add(`{"nested": {"key": "value"}}`, "nested.key", "nestedKey")
	f.Add(`{"num": 42}`, "num", "numAlias")
	f.Add(`{}`, "missing", "alias")
	f.Add(`{"arr": [1,2,3]}`, "arr", "alias")
	f.Add(`{"key": "value"}`, "", "alias")

	f.Fuzz(func(t *testing.T, jsonContent, path, objectAlias string) {
		// jmesPath.Search panics on invalid json or invalid path for a given json.
		// I sanitized the input so we don't get panics in this test.
		// This does shrink the fuzz space quite a bit.
		var obj map[string]interface{}
		if json.Unmarshal([]byte(jsonContent), &obj) != nil {
			return
		}
		if !jmesPathSearchable(path, obj) {
			return
		}

		sv := &SecretValue{
			Value: []byte(jsonContent),
			Descriptor: SecretDescriptor{
				ObjectName: "fuzzObject",
				ObjectType: "secretsmanager",
				JMESPath: []JMESPathEntry{
					{
						Path:        path,
						ObjectAlias: objectAlias,
					},
				},
			},
		}
		sv.getJsonSecrets()
	})
}

func jmesPathSearchable(path string, data interface{}) (ok bool) {
	defer func() {
		if recover() != nil {
			ok = false
		}
	}()
	jmespath.Search(path, data)
	return true
}
