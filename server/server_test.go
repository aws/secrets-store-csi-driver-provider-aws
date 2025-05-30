package server

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	secretsmanagertypes "github.com/aws/aws-sdk-go-v2/service/secretsmanager/types"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	ssmtypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"

	corev1 "k8s.io/api/core/v1"
	"k8s.io/client-go/kubernetes/fake"
	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"
	"sigs.k8s.io/yaml"

	"github.com/aws/secrets-store-csi-driver-provider-aws/auth"
	"github.com/aws/secrets-store-csi-driver-provider-aws/provider"
)

type MockParameterStoreClient struct {
	ssm.Client
	rspCnt int
	rsp    []*ssm.GetParametersOutput
	reqErr error
}

func (m *MockParameterStoreClient) GetParameters(ctx context.Context, input *ssm.GetParametersInput, optFns ...func(*ssm.Options)) (*ssm.GetParametersOutput, error) {
	if m.rspCnt >= len(m.rsp) {
		panic(fmt.Sprintf("Got unexpected request: %+v", input))
	}
	rsp := m.rsp[m.rspCnt]
	m.rspCnt += 1
	if m.reqErr != nil {
		return nil, m.reqErr
	}
	if rsp == nil {
		return nil, fmt.Errorf("Error in GetParameters")
	}

	failed := make([]string, 0)
	for _, name := range input.Names {
		if strings.Contains(name, "Fail") {
			failed = append(failed, name)
		}
	}
	rsp.InvalidParameters = append(rsp.InvalidParameters, failed...)

	return rsp, nil
}

type MockSecretsManagerClient struct {
	secretsmanager.Client
	getCnt  int
	getRsp  []*secretsmanager.GetSecretValueOutput
	descCnt int
	descRsp []*secretsmanager.DescribeSecretOutput
	reqErr  error
}

func (m *MockSecretsManagerClient) GetSecretValue(ctx context.Context, input *secretsmanager.GetSecretValueInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.GetSecretValueOutput, error) {
	if m.getCnt >= len(m.getRsp) {
		panic(fmt.Sprintf("Got unexpected request: %+v", input))
	}
	rsp := m.getRsp[m.getCnt]
	m.getCnt += 1

	if m.reqErr != nil {
		return nil, m.reqErr
	}
	if rsp == nil {
		return nil, fmt.Errorf("Error in GetSecretValue")
	}
	return rsp, nil
}

func (m *MockSecretsManagerClient) DescribeSecret(ctx context.Context, input *secretsmanager.DescribeSecretInput, optFns ...func(*secretsmanager.Options)) (*secretsmanager.DescribeSecretOutput, error) {
	if m.descCnt >= len(m.descRsp) {
		panic(fmt.Sprintf("Got unexpected request: %+v", input))
	}
	rsp := m.descRsp[m.descCnt]
	m.descCnt += 1
	if m.reqErr != nil {
		return nil, m.reqErr
	}
	if rsp == nil {
		return nil, fmt.Errorf("Error in DescribeSecret")
	}
	return rsp, nil
}

func newServerWithMocks(tstData *testCase, driverWrites bool) *CSIDriverProviderServer {

	var ssmRsp, backupRegionSsmRsp []*ssm.GetParametersOutput
	var gsvRsp, backupRegionGsvRsp []*secretsmanager.GetSecretValueOutput
	var descRsp, backupRegionDescRsp []*secretsmanager.DescribeSecretOutput
	var reqErr, brReqErr, ssmReqErr, ssmBrReqErr error

	if tstData != nil {
		ssmRsp = tstData.ssmRsp
		gsvRsp = tstData.gsvRsp
		descRsp = tstData.descRsp
		backupRegionGsvRsp = tstData.brGsvRsp
		backupRegionDescRsp = tstData.brDescRsp
		backupRegionSsmRsp = tstData.brSsmRsp
		reqErr = tstData.reqErr
		brReqErr = tstData.brReqErr
		ssmReqErr = tstData.ssmReqErr
		ssmBrReqErr = tstData.ssmBrReqErr
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
	failoverRegion := attributes["failoverRegion"]

	nodeRegion := region
	if len(nodeRegion) == 0 {
		nodeRegion = "fakeRegion"
	}

	factory := func(configs []aws.Config, regions []string) (factory *provider.SecretProviderFactory) {
		if len(region) == 0 {
			region = nodeRegion
		}
		ssmClients := []provider.SecretsManagerClient{}
		if gsvRsp != nil || descRsp != nil || reqErr != nil {
			ssmClients = append(ssmClients, provider.SecretsManagerClient{
				Region: region,
				Client: &MockSecretsManagerClient{getRsp: gsvRsp, descRsp: descRsp, reqErr: reqErr},
			})

		}
		if backupRegionGsvRsp != nil || backupRegionDescRsp != nil || brReqErr != nil {
			ssmClients = append(ssmClients, provider.SecretsManagerClient{
				Region: failoverRegion,
				Client: &MockSecretsManagerClient{getRsp: backupRegionGsvRsp, descRsp: backupRegionDescRsp, reqErr: brReqErr},
			})
		}

		paramClients := []provider.ParameterStoreClient{}
		if ssmRsp != nil || ssmReqErr != nil {
			paramClients = append(paramClients, provider.ParameterStoreClient{
				Region: region,
				Client: &MockParameterStoreClient{rsp: ssmRsp, reqErr: ssmReqErr},
			})
		}
		if backupRegionSsmRsp != nil || ssmBrReqErr != nil {
			paramClients = append(paramClients, provider.ParameterStoreClient{
				Region:     failoverRegion,
				Client:     &MockParameterStoreClient{rsp: backupRegionSsmRsp, reqErr: ssmBrReqErr},
				IsFailover: true,
			})
		}

		return &provider.SecretProviderFactory{
			Providers: map[provider.SecretType]provider.SecretProvider{
				provider.SSMParameter:   provider.NewParameterStoreProviderWithClients(paramClients...),
				provider.SecretsManager: provider.NewSecretsManagerProviderWithClients(ssmClients...),
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
	testName    string
	attributes  map[string]string
	mountObjs   []map[string]interface{}
	ssmRsp      []*ssm.GetParametersOutput
	brSsmRsp    []*ssm.GetParametersOutput
	gsvRsp      []*secretsmanager.GetSecretValueOutput
	brGsvRsp    []*secretsmanager.GetSecretValueOutput
	descRsp     []*secretsmanager.DescribeSecretOutput
	brDescRsp   []*secretsmanager.DescribeSecretOutput
	ssmReqErr   error
	ssmBrReqErr error
	reqErr      error
	brReqErr    error
	expErr      string
	brExpErr    string
	expSecrets  map[string]string
	perms       string
}

func buildMountReq(t *testing.T, dir string, tst testCase, curState []*v1alpha1.ObjectVersion) *v1alpha1.MountRequest {
	t.Helper()

	attrMap := make(map[string]string)
	attrMap["csi.storage.k8s.io/pod.name"] = tst.attributes["podName"]
	attrMap["csi.storage.k8s.io/pod.namespace"] = tst.attributes["namespace"]
	attrMap["csi.storage.k8s.io/serviceAccount.name"] = tst.attributes["accName"]

	region := tst.attributes["region"]
	if len(region) > 0 && !strings.Contains(region, "Fail") {
		attrMap["region"] = region
	}

	failoverRegion := tst.attributes["failoverRegion"]
	if len(failoverRegion) > 0 {
		attrMap["failoverRegion"] = failoverRegion
	}

	translate := tst.attributes["pathTranslation"]
	if len(translate) > 0 {
		attrMap["pathTranslation"] = translate
	}

	usePodIdentity := tst.attributes["usePodIdentity"]
	if len(usePodIdentity) > 0 {
		attrMap["usePodIdentity"] = usePodIdentity
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

// resolveFilePath returns the expected filename taking into consideration the translate flag.
func resolveFilePath(fileName string, translate string) string {
	if len(translate) == 0 {
		translate = "_" // Use default
	} else if strings.ToLower(translate) == "false" {
		translate = "" // Turn it off.
	}

	// Translate slashes to underscore if required.
	if len(translate) != 0 {
		fileName = strings.ReplaceAll(fileName, string(os.PathSeparator), translate)
	} else {
		fileName = strings.TrimLeft(fileName, string(os.PathSeparator))
	}
	return fileName
}

// createFilePermissionMapping returns a map of fileNames -> filePermission mappings.
//
// createFilePermissionMapping takes in testCase and creates the keys by calling the resolveFilePath
// the values are extracted from the testCase or inherited if not specified.
func createFilePermissionMapping(tst *testCase) map[string]string {
	// Extract the path translation
	translate := tst.attributes["pathTranslation"]

	// Create the fileNames -> filePermission map
	fileToPermissionMap := make(map[string]string)

	// Proccess the mountobjects
	for _, obj := range tst.mountObjs {
		// Extract the parent name/alias
		parentName, _ := obj["objectName"].(string)
		if objectAlias, ok := obj["objectAlias"].(string); ok {
			parentName = objectAlias
		}

		parentName = resolveFilePath(parentName, translate)

		// Extract parent file permission
		parentFilePermission := "0644"
		if filePermission, ok := obj["filePermission"].(string); ok {
			parentFilePermission = filePermission
		}
		fileToPermissionMap[parentName] = parentFilePermission

		// Proccess the jmesPathEntries
		if jmesObjs, ok := obj["jmesPath"].([]map[string]string); ok {
			for _, jmesObj := range jmesObjs {
				jmesObjectAlias, _ := jmesObj["objectAlias"]
				jmesObjectAlias = resolveFilePath(jmesObjectAlias, translate)
				if filePermission, ok := jmesObj["filePermission"]; ok {
					fileToPermissionMap[jmesObjectAlias] = filePermission
				} else {
					fileToPermissionMap[jmesObjectAlias] = parentFilePermission
				}
			}
		}
	}
	return fileToPermissionMap
}

func validateMounts(t *testing.T, dir string, tst testCase, rsp *v1alpha1.MountResponse) bool {

	// Make sure the mount response does not contain the Files attribute
	if rsp != nil && rsp.Files != nil && len(rsp.Files) > 0 {
		t.Errorf("%s: Mount response can not contain Files attribute when driverWriteSecrets is false", tst.testName)
		return false
	}

	// Parse the mount objects and extract specified file permission
	expectedPermissionMap := createFilePermissionMapping(&tst)

	// Check for the expected secrets
	for file, val := range tst.expSecrets {

		secretVal, err := os.ReadFile(filepath.Join(dir, file))
		if err != nil {
			t.Errorf("%s: Can not read file %s", tst.testName, file)
			return false
		}

		// Check secret value
		if string(secretVal) != val {
			t.Errorf("%s: Expected secret value %s got %s", tst.testName, val, string(secretVal))
			return false
		}

		// Extract expected file permission from mapping
		if expectedPermission, ok := expectedPermissionMap[file]; ok {

			// Retrieve the actual permissions for the written file
			fileInfo, err := os.Stat(filepath.Join(dir, file))
			if err != nil {
				t.Errorf("%s: Can not retrieve file's permission %s", tst.testName, file)
				return false
			}
			actualPermission := fileInfo.Mode()

			// Parse the expected file permission
			parsedPermission, err := strconv.ParseInt(expectedPermission, 8, 32)
			if err != nil {
				t.Errorf("%s: Failed to parse the permission: %s", tst.testName, expectedPermission)
				return false
			}

			// Compare the parsed file permission with the actual file permission
			if os.FileMode(parsedPermission) != actualPermission {
				t.Errorf("%s: File: %s expected file permission %v got %v", tst.testName, file, os.FileMode(parsedPermission), actualPermission)
				return false
			}
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

	// Map files to permissions
	rspPerms := make(map[string]int32)

	for _, file := range rsp.Files {
		fileRsp[file.Path] = file.Contents
		rspPerms[file.Path] = file.Mode
	}

	// Parse the mount objects and extract specified file permission
	expectedPermissionMap := createFilePermissionMapping(&tst)

	// Go through the response permissions map and ensure it matches with the expected permissions
	for file, actualPermission := range rspPerms {

		// Extract the expected file permission
		expectedPermission, ok := expectedPermissionMap[file]
		if !ok {
			t.Errorf("%s: File: %s was not expected", tst.testName, file)
			return false
		}

		// Parse the expected file permission to an octal
		parsedPermission, err := strconv.ParseInt(expectedPermission, 8, 32)
		if err != nil {
			t.Errorf("%s: Failed to parse the expected permission: %s", tst.testName, expectedPermission)
			return false
		}

		// Check if the parsed permission matches the acutal permission
		if os.FileMode(parsedPermission) != os.FileMode(actualPermission) {
			t.Errorf("%s: File: %s expected file permission %v got %v", tst.testName, file, os.FileMode(parsedPermission), os.FileMode(actualPermission))
			return false
		}
	}

	// Check default perm
	_, err := strconv.Atoi(tst.perms)
	if err != nil {
		panic(err)
	}

	// Check for the expected secrets
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
		if err := os.WriteFile(fullPath, secretVal, os.FileMode(rspPerms[file])); err != nil {
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
	{ // Vanilla Mount File Permission
		testName:   "Mount File Permission",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{
				"objectName":     "TestSecret1",
				"objectType":     "secretsmanager",
				"filePermission": "0600",
			},
		},
		ssmRsp: []*ssm.GetParametersOutput{},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String(`{"dbUser": {"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}}`), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1": `{"dbUser": {"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}}`,
		},
		perms: "420",
	},
	{ // Mount File Permission Failure
		testName:   "Mount File Permission Failure",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{
				"objectName":     "TestSecret1",
				"objectType":     "secretsmanager",
				"filePermission": "0900",
			},
		},
		ssmRsp:     []*ssm.GetParametersOutput{},
		gsvRsp:     []*secretsmanager.GetSecretValueOutput{},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "Invalid File Permission: 0900",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Mount File Permission Jmes
		testName:   "Mount JMES File Permission",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{
				"objectName":     "TestSecret1",
				"objectType":     "secretsmanager",
				"filePermission": "0600",
				"jmesPath": []map[string]string{
					{
						"path":           "dbUser.username",
						"objectAlias":    "username",
						"filePermission": "0777",
					},
					{
						"path":        "dbUser.password",
						"objectAlias": "password",
					},
				},
			},
		},
		ssmRsp: []*ssm.GetParametersOutput{},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String(`{"dbUser": {"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}}`), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1": `{"dbUser": {"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}}`,
			"username":    "SecretsManagerUser",
			"password":    "SecretsManagerPassword",
		},
		perms: "420",
	},
	{ // Mount File Permission Jmes Failure
		testName:   "Mount JMES File Permission Failure",
		attributes: stdAttributes,
		mountObjs: []map[string]interface{}{
			{
				"objectName":     "TestSecret1",
				"objectType":     "secretsmanager",
				"filePermission": "0600",
				"jmesPath": []map[string]string{
					{
						"path":           "dbUser.username",
						"objectAlias":    "username",
						"filePermission": "a987",
					},
				},
			},
		},
		ssmRsp:     []*ssm.GetParametersOutput{},
		gsvRsp:     []*secretsmanager.GetSecretValueOutput{},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "Invalid File Permission: a987",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Vanila success case.
		testName:   "New Mount Success",
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
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1": "secret1",
			"TestParm1":   "parm1",
		},
		perms: "420",
	},
	{ // Vanila success case.
		testName: "New Mount Success with usePodIdentity provided",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole", "usePodIdentity": "false",
		},
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
		expErr:  "",
		expSecrets: map[string]string{
			"TestSecret1": "secret1",
			"TestParm1":   "parm1",
		},
		perms: "420",
	},
	{ // Multi-region success case.
		testName: "Multi Region Success",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole", "failoverRegion": "fakeBackupRegion",
		},
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
			nil,
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		brGsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		brDescRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:    "",
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser", "password" : "ParameterStorePassword"}}`), Version: 1},
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
				"objectName":  "arn:aws:secretsmanager:fakeRegion:123456789012:secret:geheimnis-ABc123",
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3"), Version: 1}, // Validate out of order.
					{Name: aws.String("TestParm2"), Value: aws.String("parm2"), Version: 1},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4"), Version: 1},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5"), Version: 1},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6"), Version: 1},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7"), Version: 1},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8"), Version: 1},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9"), Version: 1},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10"), Version: 1},
				},
			},
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11"), Version: 1},
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
		testName: "Fail IRSA Session",
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
	{ // Verify failure when we can not initialize the auth session (incorrect usePodIdentity value).
		testName: "Fail Pod Identity Session",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "", "usePodIdentity": "yes",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp:     []*ssm.GetParametersOutput{},
		gsvRsp:     []*secretsmanager.GetSecretValueOutput{},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "failed to parse usePodIdentity value",
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			nil,
		},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "Failed to fetch secret",
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
		expErr:     "Failed to fetch parameters from all regions",
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3"), Version: 1},
				},
				InvalidParameters: []string{"FailParm2", "FailParm4"},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		descRsp:    []*secretsmanager.DescribeSecretOutput{},
		expErr:     "400: fakeRegion: invalid parameters: FailParm2, FailParm4",
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("../TestParm1"), Value: aws.String("parm1"), Version: 1},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("mypath/TestParm1"), Value: aws.String("parm1"), Version: 1},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("mypath/TestParm1"), Value: aws.String("parm1"), Version: 1},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("/TestParm1"), Value: aws.String("parm1"), Version: 1},
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

var stdAttributesWithBackupRegion map[string]string = map[string]string{
	"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
	"nodeName": "fakeNode", "region": "", "roleARN": "fakeRole", "failoverRegion": "fakeBackupRegion",
}

var mountTestsForMultiRegion []testCase = []testCase{
	{ // Mount secret manager secrets from the fallback region Success.
		testName:   "Multi Region Secrets Manager Fallback Success",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
		},
		gsvRsp:  []*secretsmanager.GetSecretValueOutput{nil},
		descRsp: []*secretsmanager.DescribeSecretOutput{nil},
		reqErr: &secretsmanagertypes.InternalServiceError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		brGsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestSecret1": "secret1",
		},
		perms: "420",
	},
	{ // Mount parameter secrets from the fallback region Success.
		testName:   "Multi Region Parameter Store Fallback Success",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters:        []ssmtypes.Parameter{},
				InvalidParameters: []string{("TestParm1")},
			},
		},
		ssmReqErr: &ssmtypes.InternalServerError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
				},
			},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestParm1": "parm1",
		},
		perms: "420",
	},
	{ // Mount secrets from the fallback region Success.
		testName:   "Multi Region Fallback Success",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{nil},
		ssmReqErr: &ssmtypes.InternalServerError{
			Message:           aws.String("..."),
			ErrorCodeOverride: aws.String("500")},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{nil},
		reqErr: &secretsmanagertypes.InternalServiceError{
			Message:           aws.String("..."),
			ErrorCodeOverride: aws.String("500")},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
				},
			},
		},
		brGsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		brDescRsp: []*secretsmanager.DescribeSecretOutput{},
		expErr:    "",
		expSecrets: map[string]string{
			"TestSecret1": "secret1",
			"TestParm1":   "parm1",
		},
		perms: "420",
	},
	{ // Mount secrets from the primary region Success.
		testName:   "Multi Region Prefers Primary",
		attributes: stdAttributesWithBackupRegion,
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
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("wrongSecret"), Version: 1},
				},
			},
		},
		brGsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("wrongSecret"), VersionId: aws.String("1")},
		},
		brDescRsp: []*secretsmanager.DescribeSecretOutput{
			{VersionIdsToStages: map[string][]string{"TestSecret1": {"wrongSecret"}}},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestSecret1": "secret1",
			"TestParm1":   "parm1",
		},
		perms: "420",
	},
	{ // Verify failure when the API call (GetSecretValue) fails for all the regions
		testName:   "Multi Region Secret Manager Api Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret2", "objectType": "secretsmanager"},
		},
		gsvRsp:  []*secretsmanager.GetSecretValueOutput{nil},
		descRsp: []*secretsmanager.DescribeSecretOutput{nil},
		reqErr: &secretsmanagertypes.InternalServiceError{
			Message:           aws.String("..."),
			ErrorCodeOverride: aws.String("500")},

		brGsvRsp:  []*secretsmanager.GetSecretValueOutput{nil},
		brDescRsp: []*secretsmanager.DescribeSecretOutput{nil},
		brReqErr: &secretsmanagertypes.InternalServiceError{
			Message:           aws.String("..."),
			ErrorCodeOverride: aws.String("500")},
		expErr:     "Failed to fetch secret from all regions. Verify secret exists and required permissions are granted for",
		brExpErr:   "Failed to fetch secret from all regions. Verify secret exists and required permissions are granted for:",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when API call (GetParameters) fails for all the regions
		testName:   "Multi Region Parameter Store Api Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestParm2", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{nil},
		ssmReqErr: &ssmtypes.InternalServerError{
			Message:           aws.String("..."),
			ErrorCodeOverride: aws.String("500")},
		brSsmRsp: []*ssm.GetParametersOutput{nil},
		ssmBrReqErr: &ssmtypes.InternalServerError{
			Message:           aws.String("..."),
			ErrorCodeOverride: aws.String("500")},
		expErr:     "Failed to fetch parameters from all regions.",
		brExpErr:   "Failed to fetch parameters from all regions.",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure to get region if region and node label is not available but failover region is available
		testName: "Multi Region Fallback Region Fail",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "FailNode", "region": "FailRegion", "roleARN": "fakeRole", "failoverRegion": "fakeBackupRegion",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
		},
		brGsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		brDescRsp:  []*secretsmanager.DescribeSecretOutput{},
		expErr:     "failed to retrieve region from node",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when region label is equal to backup region
		testName: "Region Equals FallbackRegion Fail",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "fakeRegion", "roleARN": "fakeRole", "failoverRegion": "fakeRegion",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
		},
		expErr:     "failover region cannot be the same as the primary region",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when we can not initialize the auth session (no role) in region and failoverRegion.
		testName: "Multi Region Session Fail",
		attributes: map[string]string{
			"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
			"nodeName": "fakeNode", "region": "fakeRegion", "roleARN": "", "failoverRegion": "fakeBackupRegion",
		},
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		expErr:     "fakeRegion: An IAM role must be associated",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Verify failure when params partially exists in primary and secondary region.
		testName:   "Multi Region Param Partial Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
			{"objectName": "TestParm2", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm2"), Value: aws.String("parm2"), Version: 1},
				},
				InvalidParameters: []string{"TestParm1"},
			},
		},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
				},
				InvalidParameters: []string{"TestParm2"},
			},
		},
		expErr:     "400: fakeRegion: invalid parameters: TestParm1",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // SecretsManager Primary Region 4XX Fail.
		testName:   "SecretsManager Primary Region 4XX Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
		},
		gsvRsp:  []*secretsmanager.GetSecretValueOutput{nil},
		descRsp: []*secretsmanager.DescribeSecretOutput{nil},
		reqErr: &secretsmanagertypes.ResourceNotFoundException{
			Message:           aws.String("Secrets Manager can't find the specified secret"),
			ErrorCodeOverride: aws.String("400")},
		brGsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		brDescRsp:  []*secretsmanager.DescribeSecretOutput{},
		expErr:     "Failed fetching secret TestSecret1",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // SecretsManager Primary Region 5XX Fail.
		testName:   "SecretsManager Primary Region 5XX Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
		},
		gsvRsp:  []*secretsmanager.GetSecretValueOutput{nil},
		descRsp: []*secretsmanager.DescribeSecretOutput{nil},
		reqErr: &secretsmanagertypes.InternalServiceError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		brGsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		brDescRsp: []*secretsmanager.DescribeSecretOutput{nil},
		expErr:    "",
		expSecrets: map[string]string{
			"TestSecret1": "secret1",
		},
		perms: "420",
	},
	{ // SecretsManager Primary Region 5XX and Secondary 4XX Fail.
		testName:   "SecretsManager Primary Region 5XX And Secondary Region 4XX Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
		},
		gsvRsp:  []*secretsmanager.GetSecretValueOutput{nil},
		descRsp: []*secretsmanager.DescribeSecretOutput{nil},
		reqErr: &secretsmanagertypes.InternalServiceError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		brGsvRsp:  []*secretsmanager.GetSecretValueOutput{nil},
		brDescRsp: []*secretsmanager.DescribeSecretOutput{nil},
		brReqErr: &secretsmanagertypes.ResourceNotFoundException{
			Message:           aws.String("Secrets Manager can't find the specified secret"),
			ErrorCodeOverride: aws.String("400")},
		expErr:     "fakeBackupRegion: Failed fetching secret TestSecret1: 400: Secrets Manager can't find the specified secret",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // ParameterStore Primary Region 4XX Fail.
		testName:   "ParameterStore Primary Region 4XX Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm2"), Value: aws.String("parm2"), Version: 1},
				},
			},
		},
		ssmReqErr: &ssmtypes.InvalidKeyId{
			Message:           aws.String("The query key ID isn't valid"),
			ErrorCodeOverride: aws.String("400")},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
				},
			},
		},
		expErr:     "fakeRegion: Failed fetching parameters: 400: The query key ID isn't valid",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // ParameterStore Primary Region 5XX Fail.
		testName:   "ParameterStore Primary Region 5XX Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{nil},
		ssmReqErr: &ssmtypes.InternalServerError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
				},
			},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestParm1": "parm1",
		},
		perms: "420",
	},
	{ // ParameterStore Primary Region 5XX and Secondary region 4XX Fail.
		testName:   "ParameterStore Primary Region 5XX And Secondary Region 4XX Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{nil},
		ssmReqErr: &ssmtypes.InternalServerError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		brSsmRsp: []*ssm.GetParametersOutput{nil},
		ssmBrReqErr: &ssmtypes.InvalidKeyId{
			Message:           aws.String("The query key ID isn't valid."),
			ErrorCodeOverride: aws.String("400")},
		expErr:     "fakeBackupRegion: Failed fetching parameters: 400: The query key ID isn't valid.",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Multi Region params Fail due to invalid params in fallback region.
		testName:   "Multi Region Param Fallback Invalid Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
			{"objectName": "TestParm2", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm2"), Value: aws.String("parm2"), Version: 1},
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
				},
			},
		},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				InvalidParameters: []string{"TestParm1", "TestParm2"},
			},
		},
		expErr:     "400: fakeBackupRegion: invalid parameters: TestParm1, TestParm2",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Multi Region params Fail due to 4XX error in fallback region.
		testName:   "Multi Region Param Fallback 4XX Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
			{"objectName": "TestParm2", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm2"), Value: aws.String("parm2"), Version: 1},
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
				},
			},
		},
		brSsmRsp: []*ssm.GetParametersOutput{nil},
		ssmBrReqErr: &ssmtypes.InvalidKeyId{
			Message:           aws.String("Failed due to Invalid KeyId"),
			ErrorCodeOverride: aws.String("400")},
		expErr:     "Failed fetching parameters: 400: Failed due to Invalid KeyId",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Multi Region Secrets fail due to 4XX in Fallback.
		testName:   "Multi Region Secrets Fallback 4XX Fail",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestSecret2", "objectType": "secretsmanager"},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
			{SecretString: aws.String("secret2"), VersionId: aws.String("1")},
		},
		descRsp:   []*secretsmanager.DescribeSecretOutput{nil},
		brGsvRsp:  []*secretsmanager.GetSecretValueOutput{nil},
		brDescRsp: []*secretsmanager.DescribeSecretOutput{nil},
		brReqErr: &secretsmanagertypes.ResourceNotFoundException{
			Message:           aws.String("Secrets Manager can't find the specified secret"),
			ErrorCodeOverride: aws.String("400")},
		expErr:     "Failed to describe secret",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Mount secret manager secrets from the fallback region Success.
		testName:   "Multi Region Secrets Manager Backup Arn Success",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{
				"objectName":  "arn:aws:secretsmanager:fakeRegion:123456789012:secret:geheimnis-ABc123",
				"backupArn":   "arn:aws:secretsmanager:fakeBackupRegion:123456789012:secret:backupArn-12345",
				"objectType":  "secretsmanager",
				"objectAlias": "TestSecret1",
			},
		},
		gsvRsp:  []*secretsmanager.GetSecretValueOutput{nil},
		descRsp: []*secretsmanager.DescribeSecretOutput{nil},
		reqErr: &secretsmanagertypes.InternalServiceError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		brGsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
		},
		brDescRsp: []*secretsmanager.DescribeSecretOutput{nil},
		expErr:    "",
		expSecrets: map[string]string{
			"TestSecret1": "secret1",
		},
		perms: "420",
	},
	{ // Test multiple SSM batches for Multi Region Fail
		testName:   "Multi Region Big Batch Fail",
		attributes: stdAttributesWithBackupRegion,
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
			{"objectName": "TestParm12", "objectType": "ssmparameter"},
			{"objectName": "TestParm13", "objectType": "ssmparameter"},
			{"objectName": "TestParm14", "objectType": "ssmparameter"},
			{"objectName": "TestParm15", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3"), Version: 1},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2"), Version: 1},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4"), Version: 1},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5"), Version: 1},
				},
				InvalidParameters: []string{"TestParm11"},
			},
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11"), Version: 1},
				},
			},
		},
		ssmReqErr: &ssmtypes.InternalServerError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
			{SecretBinary: []byte("BinarySecret"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3"), Version: 1},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2"), Version: 1},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4"), Version: 1},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5"), Version: 1},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6"), Version: 1},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7"), Version: 1},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8"), Version: 1},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9"), Version: 1},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10"), Version: 1},
				},
				InvalidParameters: []string{"TestParm11"},
			},
		},
		expErr:     "400: fakeBackupRegion: invalid parameters: TestParm11",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Test multiple SSM batches for Multi Region success
		testName:   "Multi Region Big Batch Success",
		attributes: stdAttributesWithBackupRegion,
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
			{"objectName": "TestParm12", "objectType": "ssmparameter"},
			{"objectName": "TestParm13", "objectType": "ssmparameter"},
			{"objectName": "TestParm14", "objectType": "ssmparameter"},
			{"objectName": "TestParm15", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters:        []ssmtypes.Parameter{},
				InvalidParameters: []string{},
			},
			{
				Parameters:        []ssmtypes.Parameter{},
				InvalidParameters: []string{},
			},
		},
		ssmReqErr: &ssmtypes.InternalServerError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
			{SecretBinary: []byte("BinarySecret"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3"), Version: 1},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2"), Version: 1},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4"), Version: 1},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5"), Version: 1},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6"), Version: 1},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7"), Version: 1},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8"), Version: 1},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9"), Version: 1},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10"), Version: 1},
				}},
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11"), Version: 1},
					{Name: aws.String("TestParm12"), Value: aws.String("parm12"), Version: 1},
					{Name: aws.String("TestParm13"), Value: aws.String("parm13"), Version: 1},
					{Name: aws.String("TestParm14"), Value: aws.String("parm14"), Version: 1},
					{Name: aws.String("TestParm15"), Value: aws.String("parm15"), Version: 1},
				},
			},
		},
		expErr:   "",
		brExpErr: "",
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
			"TestParm12":    "parm12",
			"TestParm13":    "parm13",
			"TestParm14":    "parm14",
			"TestParm15":    "parm15",
		},
		perms: "420",
	},
	{ // Test partial SSM batches for Multi Region Fail
		testName:   "Multi Region Partial Big Batch Fail",
		attributes: stdAttributesWithBackupRegion,
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
			{"objectName": "TestParm12", "objectType": "ssmparameter"},
			{"objectName": "TestParm13", "objectType": "ssmparameter"},
			{"objectName": "TestParm14", "objectType": "ssmparameter"},
			{"objectName": "TestParm15", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3"), Version: 1},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2"), Version: 1},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4"), Version: 1},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5"), Version: 1},
				},
				InvalidParameters: []string{"TestParm6", "TestParm7", "TestParm8", "TestParm9", "TestParm10"},
			},
			{
				InvalidParameters: []string{"TestParm11", "TestParm12", "TestParm13", "TestParm14", "TestParm15"},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
			{SecretBinary: []byte("BinarySecret"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1-sec"), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3-sec"), Version: 1},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2-sec"), Version: 1},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8"), Version: 1},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9"), Version: 1},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10"), Version: 1},
				},

				InvalidParameters: []string{"TestParm4", "TestParm5", "TestParm6", "TestParm7"},
			},
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11"), Version: 1},
					{Name: aws.String("TestParm12"), Value: aws.String("parm12"), Version: 1},
					{Name: aws.String("TestParm13"), Value: aws.String("parm13"), Version: 1},
					{Name: aws.String("TestParm14"), Value: aws.String("parm14"), Version: 1},
					{Name: aws.String("TestParm15"), Value: aws.String("parm15"), Version: 1},
				},
			},
		},
		expErr:     "400: fakeRegion: invalid parameters: TestParm6, TestParm7, TestParm8, TestParm9, TestParm10",
		expSecrets: map[string]string{},
		perms:      "420",
	},
	{ // Test partial SSM batches for Multi Region with Failover Descriptor success
		testName:   "Multi Region Failover Descriptor Batch Success",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "BinarySecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm13", "objectType": "ssmparameter"},
			{"objectName": "TestParm14", "objectType": "ssmparameter"},
			{
				"objectName":    "TestParm15",
				"objectType":    "ssmparameter",
				"objectVersion": "VersionId",
				"failoverObject": map[string]string{
					"objectName":    "TestParm15AnotherRegion",
					"objectVersion": "VersionId",
				},
				"inFallback":  "true",
				"objectAlias": "TestParm15Alias",
			},
		},
		ssmRsp: []*ssm.GetParametersOutput{nil},
		ssmReqErr: &ssmtypes.InternalServerError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
			{SecretBinary: []byte("BinarySecret"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm13"), Value: aws.String("parm13"), Version: 1},
					{Name: aws.String("TestParm14"), Value: aws.String("parm14"), Version: 1},
					{Name: aws.String("TestParm15AnotherRegion"), Value: aws.String("parm15"), Version: 1},
				},
			},
		},
		expErr:   "",
		brExpErr: "",
		expSecrets: map[string]string{
			"TestSecret1":     "secret1",
			"BinarySecret1":   "BinarySecret",
			"TestParm13":      "parm13",
			"TestParm14":      "parm14",
			"TestParm15Alias": "parm15",
		},
		perms: "420",
	},
	{ // Test Json SSM batches for Multi Region success
		testName:   "Multi Region Json SSM batches success",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "BinarySecret1", "objectType": "secretsmanager"},
			{
				"objectName": "TestParm1",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssm1Username",
					},
				},
			},
			{
				"objectName": "TestParm2",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssm2Username",
					},
				},
			},
			{
				"objectName": "TestParm3",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssm3Username",
					},
				},
			},
			{
				"objectName": "TestParm4",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssm4Username",
					},
				},
			},
			{
				"objectName": "TestParm5",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssm5Username",
					},
				},
			},
			{
				"objectName": "TestParm6",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssm6Username",
					},
				},
			},
			{
				"objectName": "TestParm7",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssm7Username",
					},
				},
			},
			{
				"objectName": "TestParm8",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssm8Username",
					},
				},
			},
			{
				"objectName": "TestParm9",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssm9Username",
					},
				},
			},
			{
				"objectName": "TestParm10",
				"objectType": "ssmparameter",
				"jmesPath": []map[string]string{
					{
						"path":        "dbUser.username",
						"objectAlias": "ssm10Username",
					},
				},
			},
			{"objectName": "TestParm11", "objectType": "ssmparameter"},
			{"objectName": "TestParm12", "objectType": "ssmparameter"},
			{"objectName": "TestParm13", "objectType": "ssmparameter"},
			{"objectName": "TestParm14", "objectType": "ssmparameter"},
			{
				"objectName":    "TestParm15",
				"objectType":    "ssmparameter",
				"objectVersion": "VersionId",
				"failoverObject": map[string]string{
					"objectName":    "TestParm15AnotherRegion",
					"objectVersion": "VersionId",
				},
				"inFallback":  "true",
				"objectAlias": "TestParm15Alias",
			},
			{"objectName": "TestParm16", "objectType": "ssmparameter"},
			{"objectName": "TestParm17", "objectType": "ssmparameter"},
			{"objectName": "TestParm18", "objectType": "ssmparameter"},
			{"objectName": "TestParm19", "objectType": "ssmparameter"},
			{"objectName": "TestParm20", "objectType": "ssmparameter"},
		},
		ssmRsp: []*ssm.GetParametersOutput{nil, nil},
		ssmReqErr: &ssmtypes.InternalServerError{
			Message:           aws.String("An error occurred on the server side"),
			ErrorCodeOverride: aws.String("500")},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("1")},
			{SecretBinary: []byte("BinarySecret"), VersionId: aws.String("1")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{nil},
		brSsmRsp: []*ssm.GetParametersOutput{
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser1", "password" : "ParameterStorePassword1"}}`), Version: 1},
					{Name: aws.String("TestParm2"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser2", "password" : "ParameterStorePassword2"}}`), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser3", "password" : "ParameterStorePassword3"}}`), Version: 1},
					{Name: aws.String("TestParm4"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser4", "password" : "ParameterStorePassword4"}}`), Version: 1},
					{Name: aws.String("TestParm5"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser5", "password" : "ParameterStorePassword5"}}`), Version: 1},
					{Name: aws.String("TestParm6"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser6", "password" : "ParameterStorePassword6"}}`), Version: 1},
					{Name: aws.String("TestParm7"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser7", "password" : "ParameterStorePassword7"}}`), Version: 1},
					{Name: aws.String("TestParm8"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser8", "password" : "ParameterStorePassword8"}}`), Version: 1},
					{Name: aws.String("TestParm9"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser9", "password" : "ParameterStorePassword9"}}`), Version: 1},
					{Name: aws.String("TestParm10"), Value: aws.String(`{"dbUser": {"username": "ParameterStoreUser10", "password" : "ParameterStorePassword10"}}`), Version: 1},
				},
			},
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11"), Version: 1},
					{Name: aws.String("TestParm12"), Value: aws.String("parm12"), Version: 1},
					{Name: aws.String("TestParm13"), Value: aws.String("parm13"), Version: 1},
					{Name: aws.String("TestParm14"), Value: aws.String("parm14"), Version: 1},
					{Name: aws.String("TestParm15AnotherRegion"), Value: aws.String("parm15"), Version: 1},
					{Name: aws.String("TestParm16"), Value: aws.String("parm16"), Version: 1},
					{Name: aws.String("TestParm17"), Value: aws.String("parm17"), Version: 1},
					{Name: aws.String("TestParm18"), Value: aws.String("parm18"), Version: 1},
					{Name: aws.String("TestParm19"), Value: aws.String("parm19"), Version: 1},
					{Name: aws.String("TestParm20"), Value: aws.String("parm20"), Version: 1},
				},
			},
		},
		expErr:   "",
		brExpErr: "",
		expSecrets: map[string]string{
			"TestSecret1":     "secret1",
			"BinarySecret1":   "BinarySecret",
			"TestParm1":       `{"dbUser": {"username": "ParameterStoreUser1", "password" : "ParameterStorePassword1"}}`,
			"TestParm2":       `{"dbUser": {"username": "ParameterStoreUser2", "password" : "ParameterStorePassword2"}}`,
			"TestParm3":       `{"dbUser": {"username": "ParameterStoreUser3", "password" : "ParameterStorePassword3"}}`,
			"TestParm4":       `{"dbUser": {"username": "ParameterStoreUser4", "password" : "ParameterStorePassword4"}}`,
			"TestParm5":       `{"dbUser": {"username": "ParameterStoreUser5", "password" : "ParameterStorePassword5"}}`,
			"TestParm6":       `{"dbUser": {"username": "ParameterStoreUser6", "password" : "ParameterStorePassword6"}}`,
			"TestParm7":       `{"dbUser": {"username": "ParameterStoreUser7", "password" : "ParameterStorePassword7"}}`,
			"TestParm8":       `{"dbUser": {"username": "ParameterStoreUser8", "password" : "ParameterStorePassword8"}}`,
			"TestParm9":       `{"dbUser": {"username": "ParameterStoreUser9", "password" : "ParameterStorePassword9"}}`,
			"TestParm10":      `{"dbUser": {"username": "ParameterStoreUser10", "password" : "ParameterStorePassword10"}}`,
			"ssm1Username":    "ParameterStoreUser1",
			"ssm2Username":    "ParameterStoreUser2",
			"ssm3Username":    "ParameterStoreUser3",
			"ssm4Username":    "ParameterStoreUser4",
			"ssm5Username":    "ParameterStoreUser5",
			"ssm6Username":    "ParameterStoreUser6",
			"ssm7Username":    "ParameterStoreUser7",
			"ssm8Username":    "ParameterStoreUser8",
			"ssm9Username":    "ParameterStoreUser9",
			"ssm10Username":   "ParameterStoreUser10",
			"TestParm11":      "parm11",
			"TestParm12":      "parm12",
			"TestParm13":      "parm13",
			"TestParm14":      "parm14",
			"TestParm15Alias": "parm15",
			"TestParm16":      "parm16",
			"TestParm17":      "parm17",
			"TestParm18":      "parm18",
			"TestParm19":      "parm19",
			"TestParm20":      "parm20",
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 1},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("mypath/TestParm1"), Value: aws.String("parm1"), Version: 1},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("/mypath/TestParm1"), Value: aws.String("parm1"), Version: 1},
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
	testCases := append(mountTests, mountTestsForMultiRegion...)
	allTests := append(testCases, writeOnlyMountTests...)
	for _, tst := range allTests {

		t.Run(tst.testName, func(t *testing.T) {

			dir := t.TempDir() // t.TempDir() handles cleanup automatically
			svr := newServerWithMocks(&tst, false)

			// Do the mount
			req := buildMountReq(t, dir, tst, []*v1alpha1.ObjectVersion{})
			rsp, err := svr.Mount(context.Background(), req)
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
			if len(tst.brExpErr) != 0 && !regexp.MustCompile(tst.brExpErr).MatchString(err.Error()) {
				t.Fatalf("%s: Expected error %s got %s", tst.testName, tst.expErr, err.Error())
			}
			validateMounts(t, req.TargetPath, tst, rsp)

		})

	}

}

func TestMountsNoWrite(t *testing.T) {
	testCases := append(mountTests, mountTestsForMultiRegion...)
	allTests := append(testCases, noWriteMountTests...)
	for _, tst := range allTests {

		t.Run(tst.testName, func(t *testing.T) {

			dir := t.TempDir() // t.TempDir() handles cleanup automatically

			svr := newServerWithMocks(&tst, true)

			// Do the mount
			req := buildMountReq(t, dir, tst, []*v1alpha1.ObjectVersion{})
			rsp, err := svr.Mount(context.Background(), req)
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
			if len(tst.brExpErr) != 0 && !regexp.MustCompile(tst.brExpErr).MatchString(err.Error()) {
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
			{"objectName": "TestSecretJSON", "objectType": "secretsmanager", "jmesPath": []map[string]string{{"path": "username", "objectAlias": "username"}}},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1 v1"), Version: 1},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2 v1"), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3 v1"), Version: 1},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4 v1"), Version: 1},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5 v1"), Version: 1},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6 v1"), Version: 1},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7 v1"), Version: 1},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8 v1"), Version: 1},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9 v1"), Version: 1},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10 v1"), Version: 1},
				},
			},
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11 v1"), Version: 1},
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
			"TestSecret1":    "TestSecret1 v1",
			"TestSecret2":    "TestSecret2 v1",
			"TestSecret3":    "TestSecret3 v1",
			"TestSecretJSON": `{"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}`,
			"username":       "SecretsManagerUser",
			"TestParm1":      "parm1 v1",
			"TestParm2":      "parm2 v1",
			"TestParm3":      "parm3 v1",
			"TestParm4":      "parm4 v1",
			"TestParm5":      "parm5 v1",
			"TestParm6":      "parm6 v1",
			"TestParm7":      "parm7 v1",
			"TestParm8":      "parm8 v1",
			"TestParm9":      "parm9 v1",
			"TestParm10":     "parm10 v1",
			"TestParm11":     "parm11 v1",
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
			{"objectName": "TestSecretJSON", "objectType": "secretsmanager", "jmesPath": []map[string]string{{"path": "username", "objectAlias": "username"}}},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1 v1"), Version: 1},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2 v1"), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3 v1"), Version: 1},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4 v1"), Version: 1},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5 v1"), Version: 1},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6 v1"), Version: 1},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7 v1"), Version: 1},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8 v1"), Version: 1},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9 v1"), Version: 1},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10 v1"), Version: 1},
				},
			},
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11 v1"), Version: 1},
				},
			},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{}, // Should be describe only
		descRsp: []*secretsmanager.DescribeSecretOutput{
			{VersionIdsToStages: map[string][]string{"TestSecret1-1": {"AWSPENDING", "AWSCURRENT"}}},
			{VersionIdsToStages: map[string][]string{"TestSecret2-1": {"custom", "AWSCURRENT"}}},
			{VersionIdsToStages: map[string][]string{"TestSecretJSON-1": {"AWSCURRENT"}}},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestSecret1":    "TestSecret1 v1",
			"TestSecret2":    "TestSecret2 v1",
			"TestSecret3":    "TestSecret3 v1",
			"TestSecretJSON": `{"username": "SecretsManagerUser", "password": "SecretsManagerPassword"}`,
			"username":       "SecretsManagerUser",
			"TestParm1":      "parm1 v1",
			"TestParm2":      "parm2 v1",
			"TestParm3":      "parm3 v1",
			"TestParm4":      "parm4 v1",
			"TestParm5":      "parm5 v1",
			"TestParm6":      "parm6 v1",
			"TestParm7":      "parm7 v1",
			"TestParm8":      "parm8 v1",
			"TestParm9":      "parm9 v1",
			"TestParm10":     "parm10 v1",
			"TestParm11":     "parm11 v1",
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
			{"objectName": "TestSecretJSON", "objectType": "secretsmanager", "jmesPath": []map[string]string{{"path": "username", "objectAlias": "username"}}},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1 v2"), Version: 2},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2 v1"), Version: 1},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3 v1"), Version: 1},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4 v2"), Version: 2},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5 v2"), Version: 2},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6 v2"), Version: 2},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7 v2"), Version: 2},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8 v2"), Version: 2},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9 v2"), Version: 2},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10 v2"), Version: 2},
				},
			},
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11 v2"), Version: 2},
				},
			},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{
			{VersionIdsToStages: map[string][]string{
				"TestSecret1-1": {"AWSPREVIOUS"},
				"TestSecret1-2": {"AWSCURRENT", "AWSPENDING"},
			}},
			{VersionIdsToStages: map[string][]string{
				"TestSecret2-1": {"custom", "AWSPREVIOUS"},
				"TestSecret2-2": {"AWSCURRENT"},
			}},
			{VersionIdsToStages: map[string][]string{"TestSecretJSON-1": {"AWSPREVIOUS"}}},
		}, // Only should retrive TestSecret1
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretBinary: []byte("TestSecret1 v2"), VersionId: aws.String("TestSecret1-2")}, // Binary secret
			{SecretString: aws.String(`{"username": "SecretsManagerUser2", "password": "SecretsManagerPassword"}`), VersionId: aws.String("TestSecretJSON-2")},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestSecret1":    "TestSecret1 v2",
			"TestSecret2":    "TestSecret2 v1",
			"TestSecret3":    "TestSecret3 v1",
			"TestSecretJSON": `{"username": "SecretsManagerUser2", "password": "SecretsManagerPassword"}`,
			"username":       "SecretsManagerUser2",
			"TestParm1":      "parm1 v2",
			"TestParm2":      "parm2 v1",
			"TestParm3":      "parm3 v1",
			"TestParm4":      "parm4 v2",
			"TestParm5":      "parm5 v2",
			"TestParm6":      "parm6 v2",
			"TestParm7":      "parm7 v2",
			"TestParm8":      "parm8 v2",
			"TestParm9":      "parm9 v2",
			"TestParm10":     "parm10 v2",
			"TestParm11":     "parm11 v2",
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
			{"objectName": "TestSecretJSON", "objectType": "secretsmanager", "jmesPath": []map[string]string{{"path": "username", "objectAlias": "username"}}},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1 v2"), Version: 2},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2 v2"), Version: 2},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3 v1"), Version: 1},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4 v2"), Version: 2},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5 v2"), Version: 2},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6 v2"), Version: 2},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7 v2"), Version: 2},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8 v2"), Version: 2},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9 v2"), Version: 2},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10 v2"), Version: 2},
				},
			},
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11 v2"), Version: 2},
				},
			},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{
			{VersionIdsToStages: map[string][]string{
				"TestSecret1-1": {"AWSPREVIOUS"},
				"TestSecret1-2": {"AWSCURRENT", "AWSPENDING"},
			}},
			{VersionIdsToStages: map[string][]string{
				"TestSecret2-1": {"AWSPREVIOUS"},
				"TestSecret2-2": {"custom", "AWSCURRENT"},
			}},
			{VersionIdsToStages: map[string][]string{"TestSecretJSON-2": {"AWSCURRENT"}}},
		}, // Only should retrive TestSecret1
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("TestSecret2 v2"), VersionId: aws.String("TestSecret2-2")},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestSecret1":    "TestSecret1 v2",
			"TestSecret2":    "TestSecret2 v2",
			"TestSecret3":    "TestSecret3 v1",
			"TestSecretJSON": `{"username": "SecretsManagerUser2", "password": "SecretsManagerPassword"}`,
			"username":       "SecretsManagerUser2",
			"TestParm1":      "parm1 v2",
			"TestParm2":      "parm2 v2",
			"TestParm3":      "parm3 v1",
			"TestParm4":      "parm4 v2",
			"TestParm5":      "parm5 v2",
			"TestParm6":      "parm6 v2",
			"TestParm7":      "parm7 v2",
			"TestParm8":      "parm8 v2",
			"TestParm9":      "parm9 v2",
			"TestParm10":     "parm10 v2",
			"TestParm11":     "parm11 v2",
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
			{"objectName": "TestSecretJSON", "objectType": "secretsmanager", "jmesPath": []map[string]string{{"path": "username", "objectAlias": "username"}}},
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
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm1"), Value: aws.String("parm1 v2"), Version: 2},
					{Name: aws.String("TestParm2"), Value: aws.String("parm2 v2"), Version: 2},
					{Name: aws.String("TestParm3"), Value: aws.String("parm3 v2"), Version: 2},
					{Name: aws.String("TestParm4"), Value: aws.String("parm4 v2"), Version: 2},
					{Name: aws.String("TestParm5"), Value: aws.String("parm5 v2"), Version: 2},
					{Name: aws.String("TestParm6"), Value: aws.String("parm6 v2"), Version: 2},
					{Name: aws.String("TestParm7"), Value: aws.String("parm7 v2"), Version: 2},
					{Name: aws.String("TestParm8"), Value: aws.String("parm8 v2"), Version: 2},
					{Name: aws.String("TestParm9"), Value: aws.String("parm9 v2"), Version: 2},
					{Name: aws.String("TestParm10"), Value: aws.String("parm10 v2"), Version: 2},
				},
			},
			{
				Parameters: []ssmtypes.Parameter{
					{Name: aws.String("TestParm11"), Value: aws.String("parm11 v2"), Version: 2},
				},
			},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{
			{VersionIdsToStages: map[string][]string{
				"TestSecret1-1": {"AWSPREVIOUS"},
				"TestSecret1-2": {"AWSCURRENT", "AWSPENDING"},
			}},
			{VersionIdsToStages: map[string][]string{
				"TestSecret2-1": {"AWSPREVIOUS"},
				"TestSecret2-2": {"custom", "AWSCURRENT"},
			}},
			{VersionIdsToStages: map[string][]string{"TestSecretJSON-2": {"AWSCURRENT"}}},
		}, // Only should retrive TestSecret1
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("TestSecret3 v2"), VersionId: aws.String("TestSecret3-2")},
		},
		expErr: "",
		expSecrets: map[string]string{
			"TestSecret1":    "TestSecret1 v2",
			"TestSecret2":    "TestSecret2 v2",
			"TestSecret3":    "TestSecret3 v2",
			"TestSecretJSON": `{"username": "SecretsManagerUser2", "password": "SecretsManagerPassword"}`,
			"username":       "SecretsManagerUser2",
			"TestParm1":      "parm1 v2",
			"TestParm2":      "parm2 v2",
			"TestParm3":      "parm3 v2",
			"TestParm4":      "parm4 v2",
			"TestParm5":      "parm5 v2",
			"TestParm6":      "parm6 v2",
			"TestParm7":      "parm7 v2",
			"TestParm8":      "parm8 v2",
			"TestParm9":      "parm9 v2",
			"TestParm10":     "parm10 v2",
			"TestParm11":     "parm11 v2",
		},
		perms: "420",
	},
}

// Validate rotation
func TestReMounts(t *testing.T) {

	dir := t.TempDir() // t.TempDir() handles cleanup automatically

	curState := []*v1alpha1.ObjectVersion{}

	for _, tst := range remountTests {

		t.Run(tst.testName, func(t *testing.T) {

			svr := newServerWithMocks(&tst, false)

			// Do the mount
			req := buildMountReq(t, dir, tst, curState)
			rsp, err := svr.Mount(context.Background(), req)
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

	dir := t.TempDir() // t.TempDir() handles cleanup automatically

	curState := []*v1alpha1.ObjectVersion{}

	for _, tst := range remountTests {

		t.Run(tst.testName, func(t *testing.T) {

			svr := newServerWithMocks(&tst, true)

			// Do the mount
			req := buildMountReq(t, dir, tst, curState)
			rsp, err := svr.Mount(context.Background(), req)
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
	rsp, err := svr.Mount(context.Background(), req)

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
	rsp, err := svr.Mount(context.Background(), req)

	if rsp != nil {
		t.Fatalf("TestNoPath: got unexpected response")
	} else if err == nil {
		t.Fatalf("TestNoPath: did not get error")
	} else if !strings.Contains(err.Error(), "Missing mount path") {
		t.Fatalf("TestNoPath: Unexpected error %s", err.Error())
	}

}

func TestGetRegionFromNodeWithAWSRegionEnvVar(t *testing.T) {
	// Test with AWS_REGION set
	os.Setenv("AWS_REGION", "us-west-2")
	defer os.Unsetenv("AWS_REGION")

	svr := newServerWithMocks(&testCase{
		testName: "Get Region From AWS_REGION Env",
		attributes: map[string]string{
			"namespace": "fakeNS",
			"podName":   "fakePod",
			"nodeName":  "fakeNode",
		},
	}, false)

	region, err := svr.getRegionFromNode(context.TODO(), "fakeNS", "fakePod")

	if err != nil {
		t.Fatalf("Expected no error with AWS_REGION set, got: %v", err)
	}
	if region != "us-west-2" {
		t.Fatalf("Expected region us-west-2, got: %s", region)
	}
}

func TestGetRegionFromNodeWithNodeLabels(t *testing.T) {
	// Test with AWS_REGION not set
	os.Unsetenv("AWS_REGION")

	svr := newServerWithMocks(&testCase{
		testName: "Get Region From Node Labels",
		attributes: map[string]string{
			"namespace": "fakeNS",
			"podName":   "fakePod",
			"nodeName":  "fakeNode",
		},
	}, false)

	region, err := svr.getRegionFromNode(context.TODO(), "fakeNS", "fakePod")
	if err != nil {
		t.Fatalf("Expected no error with node labels, got: %v", err)
	}
	if region != "fakeRegion" {
		t.Fatalf("Expected region fakeRegion, got: %s", region)
	}
}

func TestGetRegionFromNodeError(t *testing.T) {
	// Test error case when no region available
	os.Unsetenv("AWS_REGION")

	svr := newServerWithMocks(&testCase{
		testName: "Get Region Error",
		attributes: map[string]string{
			"namespace": "fakeNS",
			"podName":   "fakePod",
			"nodeName":  "FailNode",
		},
	}, false)

	_, err := svr.getRegionFromNode(context.TODO(), "fakeNS", "fakePod")
	if err == nil {
		t.Fatal("Expected error when no region available")
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
