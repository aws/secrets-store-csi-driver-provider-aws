package provider

import (
	"testing"
)

func FuzzNewSecretDescriptorList(f *testing.F) {
	f.Add("/mnt", "_", `- objectName: secret1
  objectType: secretsmanager`, "us-west-2", "")
	f.Add("/mnt", "False", `- objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:test"`, "us-west-2", "")
	f.Add("/mnt", "_", `- objectName: secret1
  objectType: ssmparameter
  objectAlias: alias1
  objectVersionLabel: AWSCURRENT`, "us-west-2", "")
	f.Add("/mnt", "_", `- objectName: "arn:aws:secretsmanager:us-west-1:123456789012:secret:s1"
  failoverObject:
    objectName: "arn:aws:secretsmanager:us-west-2:123456789012:secret:s1"
  objectAlias: test`, "us-west-1", "us-west-2")
	f.Add("/mnt", "_", `- objectName: secret1
  objectType: secretsmanager
  jmesPath:
    - path: username
      objectAlias: user`, "us-west-2", "")
	f.Add("/", "-", `- objectName: my/path/secret
  objectType: secretsmanager`, "us-east-1", "")
	f.Add("/mnt", "_", `- objectName: secret1
  objectType: secretsmanager
  filePermission: "0600"`, "us-west-2", "")
	f.Add("/mnt", "_", `not valid yaml [`, "us-west-2", "")

	f.Fuzz(func(t *testing.T, mountDir, translate, objectSpec, region, failoverRegion string) {
		if len(region) == 0 {
			return
		}
		regions := []string{region}
		if len(failoverRegion) > 0 {
			regions = append(regions, failoverRegion)
		}
		NewSecretDescriptorList(mountDir, translate, objectSpec, regions)
	})
}

func FuzzValidateFilePermission(f *testing.F) {
	f.Add("")
	f.Add("0644")
	f.Add("0600")
	f.Add("0777")
	f.Add("0000")
	f.Add("9999")
	f.Add("abc")
	f.Add("00000")

	f.Fuzz(func(t *testing.T, perm string) {
		d := &SecretDescriptor{}
		d.validateFilePermission(perm)
	})
}
