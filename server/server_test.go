package server

import (
	"context"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go/aws"
	"github.com/aws/aws-sdk-go/aws/request"
	"github.com/aws/aws-sdk-go/aws/session"
	"github.com/aws/aws-sdk-go/service/secretsmanager"
	"github.com/aws/aws-sdk-go/service/secretsmanager/secretsmanageriface"
	"github.com/aws/aws-sdk-go/service/ssm"
	"github.com/aws/aws-sdk-go/service/ssm/ssmiface"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes/fake"
	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"
	"sigs.k8s.io/yaml"

	"github.com/aws/secrets-store-csi-driver-provider-aws/auth"
	"github.com/aws/secrets-store-csi-driver-provider-aws/provider"
)

type MockParameterStoreClient struct {
	ssmiface.SSMAPI
	rspCnt int
	rsp    []*ssm.GetParametersOutput
}

func (m *MockParameterStoreClient) GetParametersWithContext(
	ctx context.Context, input *ssm.GetParametersInput, options ...request.Option,
) (*ssm.GetParametersOutput, error) {
	if m.rspCnt >= len(m.rsp) {
		panic(fmt.Sprintf("Got unexpected request: %+v", input))
	}
	rsp := m.rsp[m.rspCnt]
	m.rspCnt += 1
	if rsp == nil {
		return nil, fmt.Errorf("Error in GetParameters")
	}

	if len(rsp.Parameters) != len(input.Names) {
		panic("Batch request size not equal to resposne size")
	}
	failed := make([]*string, 0)
	for _, name := range input.Names {
		if strings.Contains(*name, "Fail") {
			failed = append(failed, name)
		}
	}
	rsp.InvalidParameters = failed

	return rsp, nil
}

type MockSecretsManagerClient struct {
	secretsmanageriface.SecretsManagerAPI
	getCnt  int
	getRsp  []*secretsmanager.GetSecretValueOutput
	descCnt int
	descRsp []*secretsmanager.DescribeSecretOutput
}

func (m *MockSecretsManagerClient) GetSecretValueWithContext(
	ctx context.Context, input *secretsmanager.GetSecretValueInput, options ...request.Option,
) (*secretsmanager.GetSecretValueOutput, error) {
	if m.getCnt >= len(m.getRsp) {
		panic(fmt.Sprintf("Got unexpected request: %+v", input))
	}
	rsp := m.getRsp[m.getCnt]
	m.getCnt += 1
	if rsp == nil {
		return nil, fmt.Errorf("Error in GetSecretValue")
	}
	return rsp, nil
}
func (m *MockSecretsManagerClient) DescribeSecretWithContext(
	ctx context.Context, input *secretsmanager.DescribeSecretInput, options ...request.Option,
) (*secretsmanager.DescribeSecretOutput, error) {
	if m.descCnt >= len(m.descRsp) {
		panic(fmt.Sprintf("Got unexpected request: %+v", input))
	}
	rsp := m.descRsp[m.descCnt]
	m.descCnt += 1
	if rsp == nil {
		return nil, fmt.Errorf("Error in DescribeSecret")
	}
	return rsp, nil
}

func newServerWithMocks(tstData *testCase, driverWrites bool) *CSIDriverProviderServer {

	var ssmRsp []*ssm.GetParametersOutput
	var gsvRsp []*secretsmanager.GetSecretValueOutput
	var descRsp []*secretsmanager.DescribeSecretOutput
	if tstData != nil {
		ssmRsp = tstData.ssmRsp
		gsvRsp = tstData.gsvRsp
		descRsp = tstData.descRsp
	}

	// Get the test attributes.
	attributes := map[string]string{}
	if tstData != nil {
		attributes = tstData.attributes
	}
	region := attributes["region"]
	nodeName := attributes["nodeName"]
	roleARN := attributes["roleARN"]
	namespace := attributes["namespace"]
	accName := attributes["accName"]
	podName := attributes["podName"]

	factory := func(region string, session *session.Session) (factory *provider.SecretProviderFactory) {
		return &provider.SecretProviderFactory{
			Providers: map[provider.SecretType]provider.SecretProvider{
				provider.SSMParameter:   provider.NewParameterStoreProviderWithClient(&MockParameterStoreClient{rsp: ssmRsp}),
				provider.SecretsManager: provider.NewSecretsManagerProviderWithClient(&MockSecretsManagerClient{getRsp: gsvRsp, descRsp: descRsp}),
			},
		}
	}

	sa := &corev1.ServiceAccount{}
	if !strings.Contains(accName, "Fail") {
		sa.Name = accName
	}
	sa.Namespace = namespace
	sa.Annotations = map[string]string{"eks.amazonaws.com/role-arn": roleARN}

	pod := &corev1.Pod{}
	if !strings.Contains(podName, "Fail") {
		pod.Name = podName
	}
	pod.Namespace = namespace
	pod.Spec.NodeName = nodeName

	node := &corev1.Node{}
	if !strings.Contains(nodeName, "Fail") {
		node.Name = nodeName
	}

	nodeRegion := region
	if len(nodeRegion) == 0 {
		nodeRegion = "fakeRegion"
	}
	if !strings.Contains(region, "Fail") {
		node.ObjectMeta.Labels = map[string]string{"topology.kubernetes.io/region": nodeRegion}
	}

	clientset := fake.NewSimpleClientset(sa, pod, node)

	return &CSIDriverProviderServer{
		secretProviderFactory: factory,
		k8sClient:             clientset.CoreV1(),
		driverWriteSecrets:    driverWrites,
	}

}

type testCase struct {
	testName   string
	attributes map[string]string
	mountObjs  []map[string]interface{}
	ssmRsp     []*ssm.GetParametersOutput
	gsvRsp     []*secretsmanager.GetSecretValueOutput
	descRsp    []*secretsmanager.DescribeSecretOutput
	expErr     string
	expSecrets map[string]string
	perms      string
}

func buildMountReq(dir string, tst testCase, curState []*v1alpha1.ObjectVersion) *v1alpha1.MountRequest {

	attrMap := make(map[string]string)
	attrMap["csi.storage.k8s.io/pod.name"] = tst.attributes["podName"]
	attrMap["csi.storage.k8s.io/pod.namespace"] = tst.attributes["namespace"]
	attrMap["csi.storage.k8s.io/serviceAccount.name"] = tst.attributes["accName"]

	region := tst.attributes["region"]
	if len(region) > 0 && !strings.Contains(region, "Fail") {
		attrMap["region"] = region
	}

	translate := tst.attributes["pathTranslation"]
	if len(translate) > 0 {
		attrMap["pathTranslation"] = translate
	}

	objs, err := yaml.Marshal(tst.mountObjs)
	if err != nil {
		panic(err)
	}
	attrMap["objects"] = string(objs)

	attr, err := json.Marshal(attrMap)
	if err != nil {
		panic(err)
	}

	return &v1alpha1.MountRequest{
		Attributes:           string(attr),
		TargetPath:           dir,
		Permission:           tst.perms,
		CurrentObjectVersion: curState,
	}

}

func validateMounts(t *testing.T, dir string, tst testCase, rsp *v1alpha1.MountResponse) bool {

	// Make sure the mount response does not contain the Files attribute
	if rsp != nil && rsp.Files != nil && len(rsp.Files) > 0 {
		t.Errorf("%s: Mount response can not contain Files attribute when driverWriteSecrets is false", tst.testName)
		return false
	}

	// Check for the expected secrets
	for file, val := range tst.expSecrets {
		secretVal, err := ioutil.ReadFile(filepath.Join(dir, file))
		if err != nil {
			t.Errorf("%s: Can not read file %s", tst.testName, file)
			return false
		}
		if string(secretVal) != val {
			t.Errorf("%s: Expected secret value %s got %s", tst.testName, val, string(secretVal))
			return false
		}
	}

	return true
}

func validateResponse(t *testing.T, dir string, tst testCase, rsp *v1alpha1.MountResponse) bool {

	if rsp == nil { // Nothing to validate
		return false
	}

	// Make sure there is a file response
	if rsp.Files == nil || len(rsp.Files) <= 0 {
		t.Errorf("%s: Mount response must contain Files attribute when driverWriteSecrets is true", tst.testName)
		return false
	}

	// Map response by pathname
	fileRsp := make(map[string][]byte)
	for _, file := range rsp.Files {
		fileRsp[file.Path] = file.Contents
	}

	// Check for the expected secrets
	perm, err := strconv.Atoi(tst.perms)
	if err != nil {
		panic(err)
	}

	for file, val := range tst.expSecrets {
		secretVal := fileRsp[file]
		if string(secretVal) != val {
			t.Errorf("%s: Expected secret value %s got %s", tst.testName, val, string(secretVal))
			return false
		}

		// Simulate the driver wrting the files
		fullPath := filepath.Join(dir, file)
		baseDir, _ := filepath.Split(fullPath)
		if err := os.MkdirAll(baseDir, os.FileMode(0777)); err != nil {
			t.Errorf("%s: could not create base directory: %v", tst.testName, err)
			return false
		}
		if err := ioutil.WriteFile(fullPath, secretVal, os.FileMode(perm)); err != nil {
			t.Errorf("%s: could not write secret: %v", tst.testName, err)
			return false
		}

	}

	return true
}

var stdAttributes map[string]string = map[string]string{
	"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
	"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole",
}
var mountTests []testCase = []testCase{
	{ // Vanila success case.
		testName:   "New Mount Success",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1": "secret1",
			"TestParm1":   "parm1",
		},
		perms: "420",
	},
	{ // Mount a json secret
		testName:   "Mount Json Success",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{
				"objectName": "TestSecret1",
				"objectType": "secretsmanager",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "username",
					},
					{
						"path":        "dbUser.password",
						"objectAlias": "password",
					},
				},
			},
			{
				"objectName": "TestParm1",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssmUsername",
					},
					{
						"path":        "dbUser.password",
						"objectAlias": "ssmPassword",
					},
				},
			},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser", "password" : "ParameterStorePassword"}}`), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String(`{"dbUser": {"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}}`), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1": `{"dbUser": {"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}}`,
			"TestParm1":   `{"dbUser": {"username": "ParameterStoreUser", "password" : "ParameterStorePassword"}}`,
			"username":    "SecretsManagerUser",
			"password":    "SecretsManagerPassword",
			"ssmUsername": "ParameterStoreUser",
			"ssmPassword": "ParameterStorePassword",
		},
		perms: "420",
	},
	{ // Mount a json secret and specify secret arn
		testName:   "Mount Json Success-specify ARN",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{
				"objectName":  "arn:aws:secretsmanager:us-west-2:123456789012:secret:geheimnis-ABc123",
				"objectAlias": "TestSecret1",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "username",
					},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String(`{"dbUser": {"username": "SecretsManagerUser"}}`), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1": `{"dbUser": {"username": "SecretsManagerUser"}}`,
			"username":    "SecretsManagerUser",
		},
		perms: "420",
	},
	{ // Mount a binary secret
		testName:   "New Mount Binary Success",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretBinary: []byte("BinarySecret"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1": "BinarySecret",
			"TestParm1":   "parm1",
		},
		perms: "420",
	},
	{ // Test multiple SSM batches
		testName:   "Big Batch Success",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "BinarySecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
			{"objectName": "TestParm2", "objectType": "ssmparameter"},
			{"objectName": "TestParm3", "objectType": "ssmparameter"},
			{"objectName": "TestParm4", "objectType": "ssmparameter"},
			{"objectName": "TestParm5", "objectType": "ssmparameter"},
			{"objectName": "TestParm6", "objectType": "ssmparameter"},
			{"objectName": "TestParm7", "objectType": "ssmparameter"},
			{"objectName": "TestParm8", "objectType": "ssmparameter"},
			{"objectName": "TestParm9", "objectType": "ssmparameter"},
			{"objectName": "TestParm10", "objectType": "ssmparameter"},
			{"objectName": "TestParm11", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3"), Version: aws.Int64(1)}, // Validate out of order.
					{Name: aws.String("TestParm2"), Value: aws.String("parm2"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10"), Version: aws.Int64(1)},
				},
			},
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
			{SecretBinary: []byte("BinarySecret"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1":   "secret1",
			"BinarySecret1": "BinarySecret",
			"TestParm1":     "parm1",
			"TestParm2":     "parm2",
			"TestParm3":     "parm3",
			"TestParm4":     "parm4",
			"TestParm5":     "parm5",
			"TestParm6":     "parm6",
			"TestParm7":     "parm7",
			"TestParm8":     "parm8",
			"TestParm9":     "parm9",
			"TestParm10":    "parm10",
			"TestParm11":    "parm11",
		},
		perms: "420",
	},
	{ // Verify failure if we can not find the pod
		testName: "Fail Pod Retrieval",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "FailPod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp:     []*ssm.GetParametersOutput{},
		gsvRsp:     []*secretsmanager.GetSecretValueOutput{},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "failed to retrieve region",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure if we can not find the node
		testName: "Fail Node Retrieval",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "FailNode", "region": "", "roleARN": "fakeRole",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp:     []*ssm.GetParametersOutput{},
		gsvRsp:     []*secretsmanager.GetSecretValueOutput{},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "failed to retrieve region",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure if we can not find the region
		testName: "Fail Region Retrieval",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "FailRegion", "roleARN": "fakeRole",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp:     []*ssm.GetParametersOutput{},
		gsvRsp:     []*secretsmanager.GetSecretValueOutput{},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "failed to retrieve region",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure if we can not parse the file permissions.
		testName:   "Fail File Perms",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp:     []*ssm.GetParametersOutput{},
		gsvRsp:     []*secretsmanager.GetSecretValueOutput{},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "failed to unmarshal file permission",
		expSecrets: map[string]string{},
		perms:      "",
	},
	{ // Verify failure when we can not initialize the auth session (no role).
		testName: "Fail Session",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp:     []*ssm.GetParametersOutput{},
		gsvRsp:     []*secretsmanager.GetSecretValueOutput{},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "An IAM role must be associated",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when there is an error in the descriptors
		testName:   "Fail Descriptors",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectType": "ssmparameter"},
		},
		ssmRsp:     []*ssm.GetParametersOutput{},
		gsvRsp:     []*secretsmanager.GetSecretValueOutput{},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "Object name must be specified",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when we the API call (GetSecretValue) fails
		testName:   "Fail Fetch Secret",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			nil,
		},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "Failed fetching secret",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when we the API call (GetParameters) fails
		testName:   "Fail Fetch Parm",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			nil,
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "Failed fetching parameter",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when parameters in the batch fails
		testName:   "Fail Fetch Parms",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
			{"objectName": "FailParm2", "objectType": "ssmparameter"},
			{"objectName": "TestParm3", "objectType": "ssmparameter"},
			{"objectName": "FailParm4", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
					{Name: aws.String("FailParm2"), Value: aws.String("parm2"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3"), Version: aws.Int64(1)},
					{Name: aws.String("FailParm4"), Value: aws.String("parm2"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "Invalid parameters: FailParm2, FailParm4",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when we try to use a path name in a parameter (prevent traversal)
		testName: "Fail Write Param",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole",
			"pathTranslation": "False",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "../TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "(contains path separator)|(path can not contain)",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when we try to use a path name in a parameter (prevent traversal)
		testName: "Fail Write Secret",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole",
			"pathTranslation": "False",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "./../TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("../TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "(contains path separator)|(path can not contain)",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify success when slashes are translated in the path name
		testName:   "Success With Slash",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{"objectName": "mypath/TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "mypath/TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("mypath/TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"mypath_TestSecret1": "secret1",
			"mypath_TestParm1":   "parm1",
		},
		perms: "420",
	},
	{ // Verify success when slashes are translated to a custom character
		testName: "Slash to dash",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole",
			"pathTranslation": "-",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "mypath/TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "mypath/TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("mypath/TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"mypath-TestSecret1": "secret1",
			"mypath-TestParm1":   "parm1",
		},
		perms: "420",
	},
	{ // Verify failure if we use a bad path translation string
		testName: "Fail pathTranslation",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole",
			"pathTranslation": "--",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp:     []*ssm.GetParametersOutput{},
		gsvRsp:     []*secretsmanager.GetSecretValueOutput{},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "pathTranslation must be",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when we try to use a path name in a secret
		testName: "Leading Slash OK",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole",
			"pathTranslation": "False",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "/TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "/TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					&ssm.Parameter{Name: aws.String("/TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1": "secret1",
			"TestParm1":   "parm1",
		},
		perms: "420",
	},
}

// Test that only run with driverWriteSecrets = false
var writeOnlyMountTests []testCase = []testCase{
	{ // Verify failure when we try to use a path name in a secret
		testName: "Fail Write Path Secret",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole",
			"pathTranslation": "False",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "mypath/TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					&ssm.Parameter{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "contains path separator",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when we try to use a path name in a secret
		testName: "Fail Write Path Parm",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole",
			"pathTranslation": "False",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "mypath/TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					&ssm.Parameter{Name: aws.String("mypath/TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "contains path separator",
		expSecrets: map[string]string{},
		perms:      "420",
	},
}

// Test that only run with driverWriteSecrets = true
var noWriteMountTests []testCase = []testCase{
	{ // Verify success when using leading slashes with driver write
		testName: "Full path OK",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole",
			"pathTranslation": "False",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "/mypath/TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "/mypath/TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					&ssm.Parameter{Name: aws.String("/mypath/TestParm1"), Value: aws.String("parm1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"mypath/TestSecret1": "secret1",
			"mypath/TestParm1":   "parm1",
		},
		perms: "420",
	},
}

// Map test name for use as a directory
var nameCharMap map[rune]bool = map[rune]bool{filepath.Separator: true, ' ': true}

func nameMapper(c rune) rune {
	if nameCharMap[c] {
		return '_'
	}
	return c
}

func TestMounts(t *testing.T) {

	allTests := append(mountTests, writeOnlyMountTests...)
	for _, tst := range allTests {

		t.Run(tst.testName, func(t *testing.T) {

			dir, err := ioutil.TempDir("", strings.Map(nameMapper, tst.testName))
			if err != nil {
				panic(err)
			}
			defer os.RemoveAll(dir) // Cleanup

			svr := newServerWithMocks(&tst, false)

			// Do the mount
			req := buildMountReq(dir, tst, []*v1alpha1.ObjectVersion{})
			rsp, err := svr.Mount(nil, req)
			if len(tst.expErr) == 0 && err != nil {
				t.Fatalf("%s: Got unexpected error: %s", tst.testName, err)
			}
			if len(tst.expErr) != 0 && err == nil {
				t.Fatalf("%s: Expected error but got none", tst.testName)
			}
			if len(tst.expErr) == 0 && rsp == nil {
				t.Fatalf("%s: Got empty response", tst.testName)
			}
			if len(tst.expErr) != 0 && !regexp.MustCompile(tst.expErr).MatchString(err.Error()) {
				t.Fatalf("%s: Expected error %s got %s", tst.testName, tst.expErr, err.Error())
			}
			validateMounts(t, req.TargetPath, tst, rsp)

		})

	}

}

func TestMountsNoWrite(t *testing.T) {

	allTests := append(mountTests, noWriteMountTests...)
	for _, tst := range allTests {

		t.Run(tst.testName, func(t *testing.T) {

			dir, err := ioutil.TempDir("", strings.Map(nameMapper, tst.testName))
			if err != nil {
				panic(err)
			}
			defer os.RemoveAll(dir) // Cleanup

			svr := newServerWithMocks(&tst, true)

			// Do the mount
			req := buildMountReq(dir, tst, []*v1alpha1.ObjectVersion{})
			rsp, err := svr.Mount(nil, req)
			if len(tst.expErr) == 0 && err != nil {
				t.Fatalf("%s: Got unexpected error: %s", tst.testName, err)
			}
			if len(tst.expErr) != 0 && err == nil {
				t.Fatalf("%s: Expected error but got none", tst.testName)
			}
			if len(tst.expErr) == 0 && rsp == nil {
				t.Fatalf("%s: Got empty response", tst.testName)
			}
			if len(tst.expErr) != 0 && !regexp.MustCompile(tst.expErr).MatchString(err.Error()) {
				t.Fatalf("%s: Expected error %s got %s", tst.testName, tst.expErr, err.Error())
			}
			validateResponse(t, req.TargetPath, tst, rsp)

		})

	}

}

var remountTests []testCase = []testCase{

	{ // Test multiple SSM batches
		testName:   "Initial Mount Success",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			// Secrets with and without lables and versions
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestSecret2", "objectType": "secretsmanager", "objectVersionLabel": "custom"},
			{"objectName": "TestSecret3", "objectType": "secretsmanager", "objectVersion": "TestSecret3-1"},
			{"objectName": "TestSecretJSON", "objectType": "secretsmanager", "jmesPath": []map[string]string{{"path":"username", "objectAlias": "username"}}},
			// SSM parameters with and without lables and versions
			{"objectName": "TestParm1", "objectType": "ssmparameter", "objectVersionLabel": "current"},
			{"objectName": "TestParm2", "objectType": "ssmparameter", "objectVersion": "1"},
			{"objectName": "TestParm3", "objectType": "ssmparameter"},
			{"objectName": "TestParm4", "objectType": "ssmparameter"},
			{"objectName": "TestParm5", "objectType": "ssmparameter"},
			{"objectName": "TestParm6", "objectType": "ssmparameter"},
			{"objectName": "TestParm7", "objectType": "ssmparameter"},
			{"objectName": "TestParm8", "objectType": "ssmparameter"},
			{"objectName": "TestParm9", "objectType": "ssmparameter"},
			{"objectName": "TestParm10", "objectType": "ssmparameter"},
			{"objectName": "TestParm11", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10 v1"), Version: aws.Int64(1)},
				},
			},
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11 v1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretBinary: []byte("TestSecret1 v1"), VersionId: aws.String("TestSecret1-1")}, // Binary secret
			{SecretString: aws.String("TestSecret2 v1"), VersionId: aws.String("TestSecret2-1")},
			{SecretString: aws.String("TestSecret3 v1"), VersionId: aws.String("TestSecret3-1")},
			{SecretString: aws.String(`{"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}`), VersionId: aws.String("TestSecretJSON-1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1": "TestSecret1 v1",
			"TestSecret2": "TestSecret2 v1",
			"TestSecret3": "TestSecret3 v1",
			"TestSecretJSON": `{"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}`,
			"username": "SecretsManagerUser",
			"TestParm1":   "parm1 v1",
			"TestParm2":   "parm2 v1",
			"TestParm3":   "parm3 v1",
			"TestParm4":   "parm4 v1",
			"TestParm5":   "parm5 v1",
			"TestParm6":   "parm6 v1",
			"TestParm7":   "parm7 v1",
			"TestParm8":   "parm8 v1",
			"TestParm9":   "parm9 v1",
			"TestParm10":  "parm10 v1",
			"TestParm11":  "parm11 v1",
		},
		perms: "420",
	},
	{ // Test remount with no changes.
		testName:   "No Change Success",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			// Secrets with and without lables and versions
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestSecret2", "objectType": "secretsmanager", "objectVersionLabel": "custom"},
			{"objectName": "TestSecret3", "objectType": "secretsmanager", "objectVersion": "TestSecret3-1"},
			{"objectName": "TestSecretJSON", "objectType": "secretsmanager", "jmesPath": []map[string]string{{"path":"username", "objectAlias": "username"}}},
			// SSM parameters with and without lables and versions
			{"objectName": "TestParm1", "objectType": "ssmparameter", "objectVersionLabel": "current"},
			{"objectName": "TestParm2", "objectType": "ssmparameter", "objectVersion": "1"},
			{"objectName": "TestParm3", "objectType": "ssmparameter"},
			{"objectName": "TestParm4", "objectType": "ssmparameter"},
			{"objectName": "TestParm5", "objectType": "ssmparameter"},
			{"objectName": "TestParm6", "objectType": "ssmparameter"},
			{"objectName": "TestParm7", "objectType": "ssmparameter"},
			{"objectName": "TestParm8", "objectType": "ssmparameter"},
			{"objectName": "TestParm9", "objectType": "ssmparameter"},
			{"objectName": "TestParm10", "objectType": "ssmparameter"},
			{"objectName": "TestParm11", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10 v1"), Version: aws.Int64(1)},
				},
			},
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11 v1"), Version: aws.Int64(1)},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{}, // Should be describe only
		descRsp: []*secretsmanager.DescribeSecretOutput{
			{VersionIdsToStages: map[string][]*string{"TestSecret1-1": {aws.String("AWSPENDING"), aws.String("AWSCURRENT")}}},
			{VersionIdsToStages: map[string][]*string{"TestSecret2-1": {aws.String("custom"), aws.String("AWSCURRENT")}}},
			{VersionIdsToStages: map[string][]*string{"TestSecretJSON-1": {aws.String("AWSCURRENT")}}},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestSecret1": "TestSecret1 v1",
			"TestSecret2": "TestSecret2 v1",
			"TestSecret3": "TestSecret3 v1",
			"TestSecretJSON": `{"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}`,
			"username": "SecretsManagerUser",
			"TestParm1":   "parm1 v1",
			"TestParm2":   "parm2 v1",
			"TestParm3":   "parm3 v1",
			"TestParm4":   "parm4 v1",
			"TestParm5":   "parm5 v1",
			"TestParm6":   "parm6 v1",
			"TestParm7":   "parm7 v1",
			"TestParm8":   "parm8 v1",
			"TestParm9":   "parm9 v1",
			"TestParm10":  "parm10 v1",
			"TestParm11":  "parm11 v1",
		},
		perms: "420",
	},
	{ // Make sure we see changes unless we use a fixed version
		testName:   "Rotation1 Success",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			// Secrets with and without lables and versions
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestSecret2", "objectType": "secretsmanager", "objectVersionLabel": "custom"},
			{"objectName": "TestSecret3", "objectType": "secretsmanager", "objectVersion": "TestSecret3-1"},
			{"objectName": "TestSecretJSON", "objectType": "secretsmanager", "jmesPath": []map[string]string{{"path":"username", "objectAlias": "username"}}},
			// SSM parameters with and without lables and versions
			{"objectName": "TestParm1", "objectType": "ssmparameter", "objectVersionLabel": "current"},
			{"objectName": "TestParm2", "objectType": "ssmparameter", "objectVersion": "1"},
			{"objectName": "TestParm3", "objectType": "ssmparameter"},
			{"objectName": "TestParm4", "objectType": "ssmparameter"},
			{"objectName": "TestParm5", "objectType": "ssmparameter"},
			{"objectName": "TestParm6", "objectType": "ssmparameter"},
			{"objectName": "TestParm7", "objectType": "ssmparameter"},
			{"objectName": "TestParm8", "objectType": "ssmparameter"},
			{"objectName": "TestParm9", "objectType": "ssmparameter"},
			{"objectName": "TestParm10", "objectType": "ssmparameter"},
			{"objectName": "TestParm11", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10 v2"), Version: aws.Int64(2)},
				},
			},
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11 v2"), Version: aws.Int64(2)},
				},
			},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{
			{VersionIdsToStages: map[string][]*string{
				"TestSecret1-1": {aws.String("AWSPREVIOUS")},
				"TestSecret1-2": {aws.String("AWSCURRENT"), aws.String("AWSPENDING")},
			}},
			{VersionIdsToStages: map[string][]*string{
				"TestSecret2-1": {aws.String("custom"), aws.String("AWSPREVIOUS")},
				"TestSecret2-2": {aws.String("AWSCURRENT")},
			}},
			{VersionIdsToStages: map[string][]*string{"TestSecretJSON-1": {aws.String("AWSPREVIOUS")}}},
		}, // Only should retrive TestSecret1
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretBinary: []byte("TestSecret1 v2"), VersionId: aws.String("TestSecret1-2")}, // Binary secret
			{SecretString: aws.String(`{"username": "SecretsManagerUser2", "password": "SecretsManagerPassword"}`), VersionId: aws.String("TestSecretJSON-2")},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestSecret1": "TestSecret1 v2",
			"TestSecret2": "TestSecret2 v1",
			"TestSecret3": "TestSecret3 v1",
			"TestSecretJSON": `{"username": "SecretsManagerUser2", "password": "SecretsManagerPassword"}`,
			"username": "SecretsManagerUser2",
			"TestParm1":   "parm1 v2",
			"TestParm2":   "parm2 v1",
			"TestParm3":   "parm3 v1",
			"TestParm4":   "parm4 v2",
			"TestParm5":   "parm5 v2",
			"TestParm6":   "parm6 v2",
			"TestParm7":   "parm7 v2",
			"TestParm8":   "parm8 v2",
			"TestParm9":   "parm9 v2",
			"TestParm10":  "parm10 v2",
			"TestParm11":  "parm11 v2",
		},
		perms: "420",
	},
	{ // Make sure we see changes when labels are moved
		testName:   "Move Labels1 Success",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			// Secrets with and without lables and versions
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestSecret2", "objectType": "secretsmanager", "objectVersionLabel": "custom"},
			{"objectName": "TestSecret3", "objectType": "secretsmanager", "objectVersion": "TestSecret3-1"},
			{"objectName": "TestSecretJSON", "objectType": "secretsmanager", "jmesPath": []map[string]string{{"path":"username", "objectAlias": "username"}}},
			// SSM parameters with and without lables and versions
			{"objectName": "TestParm1", "objectType": "ssmparameter", "objectVersionLabel": "current"},
			{"objectName": "TestParm2", "objectType": "ssmparameter", "objectVersion": "1"},
			{"objectName": "TestParm3", "objectType": "ssmparameter"},
			{"objectName": "TestParm4", "objectType": "ssmparameter"},
			{"objectName": "TestParm5", "objectType": "ssmparameter"},
			{"objectName": "TestParm6", "objectType": "ssmparameter"},
			{"objectName": "TestParm7", "objectType": "ssmparameter"},
			{"objectName": "TestParm8", "objectType": "ssmparameter"},
			{"objectName": "TestParm9", "objectType": "ssmparameter"},
			{"objectName": "TestParm10", "objectType": "ssmparameter"},
			{"objectName": "TestParm11", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3 v1"), Version: aws.Int64(1)},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10 v2"), Version: aws.Int64(2)},
				},
			},
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11 v2"), Version: aws.Int64(2)},
				},
			},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{
			{VersionIdsToStages: map[string][]*string{
				"TestSecret1-1": {aws.String("AWSPREVIOUS")},
				"TestSecret1-2": {aws.String("AWSCURRENT"), aws.String("AWSPENDING")},
			}},
			{VersionIdsToStages: map[string][]*string{
				"TestSecret2-1": {aws.String("AWSPREVIOUS")},
				"TestSecret2-2": {aws.String("custom"), aws.String("AWSCURRENT")},
			}},
			{VersionIdsToStages: map[string][]*string{"TestSecretJSON-2": {aws.String("AWSCURRENT")}}},
		}, // Only should retrive TestSecret1
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("TestSecret2 v2"), VersionId: aws.String("TestSecret2-2")},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestSecret1": "TestSecret1 v2",
			"TestSecret2": "TestSecret2 v2",
			"TestSecret3": "TestSecret3 v1",
			"TestSecretJSON": `{"username": "SecretsManagerUser2", "password": "SecretsManagerPassword"}`,
			"username": "SecretsManagerUser2",
			"TestParm1":   "parm1 v2",
			"TestParm2":   "parm2 v2",
			"TestParm3":   "parm3 v1",
			"TestParm4":   "parm4 v2",
			"TestParm5":   "parm5 v2",
			"TestParm6":   "parm6 v2",
			"TestParm7":   "parm7 v2",
			"TestParm8":   "parm8 v2",
			"TestParm9":   "parm9 v2",
			"TestParm10":  "parm10 v2",
			"TestParm11":  "parm11 v2",
		},
		perms: "420",
	},
	{ // Make sure we see changes when we change hard coded version in the request
		testName:   "Move Version Success",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			// Secrets with and without lables and versions
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestSecret2", "objectType": "secretsmanager", "objectVersionLabel": "custom"},
			{"objectName": "TestSecret3", "objectType": "secretsmanager", "objectVersion": "TestSecret3-2"},
			{"objectName": "TestSecretJSON", "objectType": "secretsmanager", "jmesPath": []map[string]string{{"path":"username", "objectAlias": "username"}}},
			// SSM parameters with and without lables and versions
			{"objectName": "TestParm1", "objectType": "ssmparameter", "objectVersionLabel": "current"},
			{"objectName": "TestParm2", "objectType": "ssmparameter", "objectVersion": "2"},
			{"objectName": "TestParm3", "objectType": "ssmparameter"},
			{"objectName": "TestParm4", "objectType": "ssmparameter"},
			{"objectName": "TestParm5", "objectType": "ssmparameter"},
			{"objectName": "TestParm6", "objectType": "ssmparameter"},
			{"objectName": "TestParm7", "objectType": "ssmparameter"},
			{"objectName": "TestParm8", "objectType": "ssmparameter"},
			{"objectName": "TestParm9", "objectType": "ssmparameter"},
			{"objectName": "TestParm10", "objectType": "ssmparameter"},
			{"objectName": "TestParm11", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9 v2"), Version: aws.Int64(2)},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10 v2"), Version: aws.Int64(2)},
				},
			},
			{
				Parameters: []*ssm.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11 v2"), Version: aws.Int64(2)},
				},
			},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{
			{VersionIdsToStages: map[string][]*string{
				"TestSecret1-1": {aws.String("AWSPREVIOUS")},
				"TestSecret1-2": {aws.String("AWSCURRENT"), aws.String("AWSPENDING")},
			}},
			{VersionIdsToStages: map[string][]*string{
				"TestSecret2-1": {aws.String("AWSPREVIOUS")},
				"TestSecret2-2": {aws.String("custom"), aws.String("AWSCURRENT")},
			}},
			{VersionIdsToStages: map[string][]*string{"TestSecretJSON-2": {aws.String("AWSCURRENT")}}},
		}, // Only should retrive TestSecret1
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("TestSecret3 v2"), VersionId: aws.String("TestSecret3-2")},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestSecret1": "TestSecret1 v2",
			"TestSecret2": "TestSecret2 v2",
			"TestSecret3": "TestSecret3 v2",
			"TestSecretJSON": `{"username": "SecretsManagerUser2", "password": "SecretsManagerPassword"}`,
			"username": "SecretsManagerUser2",
			"TestParm1":   "parm1 v2",
			"TestParm2":   "parm2 v2",
			"TestParm3":   "parm3 v2",
			"TestParm4":   "parm4 v2",
			"TestParm5":   "parm5 v2",
			"TestParm6":   "parm6 v2",
			"TestParm7":   "parm7 v2",
			"TestParm8":   "parm8 v2",
			"TestParm9":   "parm9 v2",
			"TestParm10":  "parm10 v2",
			"TestParm11":  "parm11 v2",
		},
		perms: "420",
	},
}

// Validate rotation
func TestReMounts(t *testing.T) {

	dir, err := ioutil.TempDir("", "TestReMounts")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir) // Cleanup

	curState := []*v1alpha1.ObjectVersion{}

	for _, tst := range remountTests {

		t.Run(tst.testName, func(t *testing.T) {

			svr := newServerWithMocks(&tst, false)

			// Do the mount
			req := buildMountReq(dir, tst, curState)
			rsp, err := svr.Mount(nil, req)
			if len(tst.expErr) == 0 && err != nil {
				t.Fatalf("%s: Got unexpected error: %s", tst.testName, err)
			}
			if len(tst.expErr) != 0 && !regexp.MustCompile(tst.expErr).MatchString(err.Error()) {
				t.Fatalf("%s: Expected error %s got %s", tst.testName, tst.expErr, err.Error())
			}
			if len(tst.expErr) == 0 && rsp == nil {
				t.Fatalf("%s: Got empty response", tst.testName)
			}

			if rsp != nil {
				curState = rsp.ObjectVersion // Mount state for next iteration
			}

			validateMounts(t, req.TargetPath, tst, rsp)

		})

	}

}

// Validate rotation
func TestNoWriteReMounts(t *testing.T) {

	dir, err := ioutil.TempDir("", "TestReMounts")
	if err != nil {
		panic(err)
	}
	defer os.RemoveAll(dir) // Cleanup

	curState := []*v1alpha1.ObjectVersion{}

	for _, tst := range remountTests {

		t.Run(tst.testName, func(t *testing.T) {

			svr := newServerWithMocks(&tst, true)

			// Do the mount
			req := buildMountReq(dir, tst, curState)
			rsp, err := svr.Mount(nil, req)
			if len(tst.expErr) == 0 && err != nil {
				t.Fatalf("%s: Got unexpected error: %s", tst.testName, err)
			}
			if len(tst.expErr) != 0 && !regexp.MustCompile(tst.expErr).MatchString(err.Error()) {
				t.Fatalf("%s: Expected error %s got %s", tst.testName, tst.expErr, err.Error())
			}
			if len(tst.expErr) == 0 && rsp == nil {
				t.Fatalf("%s: Got empty response", tst.testName)
			}

			// Simulate the driver behaviour of only keeping updated secrets.
			if err := os.RemoveAll(req.TargetPath); err != nil {
				t.Fatalf("%s: could not clean directory - %v", tst.testName, err)
			}

			if rsp != nil {
				curState = rsp.ObjectVersion // Mount state for next iteration
			}

			validateResponse(t, req.TargetPath, tst, rsp)

		})

	}

}

func TestEmptyAttributes(t *testing.T) {

	svr := newServerWithMocks(nil, false)
	req := &v1alpha1.MountRequest{
		Attributes:           "", // Should error
		TargetPath:           "/tmp",
		Permission:           "420",
		CurrentObjectVersion: []*v1alpha1.ObjectVersion{},
	}
	rsp, err := svr.Mount(nil, req)

	if rsp != nil {
		t.Fatalf("TestEmptyAttributes: got unexpected response")
	} else if err == nil {
		t.Fatalf("TestEmptyAttributes: did not get error")
	} else if !strings.Contains(err.Error(), "failed to unmarshal attributes") {
		t.Fatalf("TestEmptyAttributes: Unexpected error %s", err.Error())
	}

}

func TestNoPath(t *testing.T) {

	svr := newServerWithMocks(nil, false)
	req := &v1alpha1.MountRequest{ // Missing TargetPath
		Attributes:           "{}",
		Permission:           "420",
		CurrentObjectVersion: []*v1alpha1.ObjectVersion{},
	}
	rsp, err := svr.Mount(nil, req)

	if rsp != nil {
		t.Fatalf("TestNoPath: got unexpected response")
	} else if err == nil {
		t.Fatalf("TestNoPath: did not get error")
	} else if !strings.Contains(err.Error(), "Missing mount path") {
		t.Fatalf("TestNoPath: Unexpected error %s", err.Error())
	}

}

// Make sure the Version call works
func TestDriverVersion(t *testing.T) {

	svr, err := NewServer(nil, nil, true)
	if err != nil {
		t.Fatalf("TestDriverVersion: got unexpected server error %s", err.Error())
	}
	if svr == nil {
		t.Fatalf("TestDriverVersion: got empty server")
	}

	ver, err := svr.Version(nil, &v1alpha1.VersionRequest{})
	if err != nil {
		t.Fatalf("TestDriverVersion: got unexpected error %s", err.Error())
	}
	if ver == nil {
		t.Fatalf("TestDriverVersion: got empty response")
	}
	if ver.RuntimeName != auth.ProviderName {
		t.Fatalf("TestDriverVersion: wrong RuntimeName: %s", ver.RuntimeName)
	}
}
