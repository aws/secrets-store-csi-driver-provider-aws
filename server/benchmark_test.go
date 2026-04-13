// Benchmarks for the server package covering end-to-end mount request
// handling with mocked AWS clients (single secret, mixed types, JMES path
// extraction, and large batches).
// All benchmark tests benchmark both server initialization and mount requests.
// Run with: go test -bench=. -benchmem ./server/
package server

import (
	"context"
	"encoding/json"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	ssmtypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"
	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"
	"sigs.k8s.io/yaml"
)

func buildBenchMountReq(dir string, tst testCase) *v1alpha1.MountRequest {
	attrMap := map[string]string{
		"csi.storage.k8s.io/pod.name":            tst.attributes["podName"],
		"csi.storage.k8s.io/pod.namespace":       tst.attributes["namespace"],
		"csi.storage.k8s.io/serviceAccount.name": tst.attributes["accName"],
	}
	if r := tst.attributes["region"]; len(r) > 0 {
		attrMap["region"] = r
	}
	if fr := tst.attributes["failoverRegion"]; len(fr) > 0 {
		attrMap["failoverRegion"] = fr
	}
	if pt := tst.attributes["pathTranslation"]; len(pt) > 0 {
		attrMap["pathTranslation"] = pt
	}

	objs, _ := yaml.Marshal(tst.mountObjs)
	attrMap["objects"] = string(objs)
	attr, _ := json.Marshal(attrMap)

	return &v1alpha1.MountRequest{
		Attributes:           string(attr),
		TargetPath:           dir,
		Permission:           tst.perms,
		CurrentObjectVersion: []*v1alpha1.ObjectVersion{},
	}
}

func BenchmarkMount_SingleSecret(b *testing.B) {
	tst := testCase{
		testName:   "Bench Single Secret",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
		},
		ssmRsp: []*ssm.GetParametersOutput{},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		perms:   "420",
	}

	for b.Loop() {
		dir := b.TempDir()
		svr := newServerWithMocks(&tst, true, nil)
		req := buildBenchMountReq(dir, tst)

		if _, err := svr.Mount(context.Background(), req); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkMount_MixedSecrets(b *testing.B) {
	tst := testCase{
		testName:   "Bench Mixed",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		perms:   "420",
	}

	for b.Loop() {
		dir := b.TempDir()
		svr := newServerWithMocks(&tst, true, nil)
		req := buildBenchMountReq(dir, tst)
		if _, err := svr.Mount(context.Background(), req); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkMount_WithJMESPath(b *testing.B) {
	tst := testCase{
		testName:   "Bench JMES",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{
				"objectName": "TestSecret1",
				"objectType": "secretsmanager",
				"jmesPath": []map[string]string{
					{"path": "dbUser.username", "objectAlias": "username"},
					{"path": "dbUser.password", "objectAlias": "password"},
				},
			},
		},
		ssmRsp: []*ssm.GetParametersOutput{},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String(`{"dbUser": {"username": "user1", "password": "pass1"}}`), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		perms:   "420",
	}

	for b.Loop() {
		dir := b.TempDir()
		svr := newServerWithMocks(&tst, true, nil)
		req := buildBenchMountReq(dir, tst)
		if _, err := svr.Mount(context.Background(), req); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkMount_LargeBatch(b *testing.B) {
	mountObjs := make([]map[string]interface{}, 15)
	params := make([]ssmtypes.Parameter, 15)
	for i := range 15 {
		name := "TestParm" + string(rune('A'+i))
		mountObjs[i] = map[string]interface{}{"objectName": name, "objectType": "ssmparameter"}
		params[i] = ssmtypes.Parameter{Name: aws.String(name), Value: aws.String("val"), Version: 1}
	}

	tst := testCase{
		testName:   "Bench Large Batch",
		attributes: stdAttributes,
		mountObjs:  mountObjs,
		ssmRsp: []*ssm.GetParametersOutput{
			{Parameters: params[:10]},
			{Parameters: params[10:]},
		},
		gsvRsp:  []*secretsmanager.GetSecretValueOutput{},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		perms:   "420",
	}

	for b.Loop() {
		dir := b.TempDir()
		svr := newServerWithMocks(&tst, true, nil)
		req := buildBenchMountReq(dir, tst)
		svr.Mount(context.Background(), req)
		if _, err := svr.Mount(context.Background(), req); err != nil {
			b.Fatal(err)
		}
	}
}
