package server

import (
	"context"
	"testing"

	"github.com/aws/aws-sdk-go-v2/aws"
	"github.com/aws/aws-sdk-go-v2/service/secretsmanager"
	"github.com/aws/aws-sdk-go-v2/service/ssm"
	ssmtypes "github.com/aws/aws-sdk-go-v2/service/ssm/types"

	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"
)

// Versions reported to the driver must come from the region that supplied the
// mounted value. A failover copy that is never rotated otherwise pins the
// reported version, so the driver sees no change and does not resync.
func TestMultiRegionReportsPrimaryVersion(t *testing.T) {

	tst := testCase{
		testName:   "Multi Region Reports Primary Version",
		attributes: stdAttributesWithBackupRegion,
		mountObjs: []map[string]interface{}{
			{"objectName": "TestSecret1", "objectType": "secretsmanager"},
			{"objectName": "TestParm1", "objectType": "ssmparameter"},
		},
		gsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("secret1"), VersionId: aws.String("primaryVersion")},
		},
		descRsp: []*secretsmanager.DescribeSecretOutput{},
		brGsvRsp: []*secretsmanager.GetSecretValueOutput{
			{SecretString: aws.String("staleSecret1"), VersionId: aws.String("failoverVersion")},
		},
		brDescRsp: []*secretsmanager.DescribeSecretOutput{
			{VersionIdsToStages: map[string][]string{"failoverVersion": {"AWSCURRENT"}}},
		},
		ssmRsp: []*ssm.GetParametersOutput{
			{Parameters: []ssmtypes.Parameter{
				{Name: aws.String("TestParm1"), Value: aws.String("parm1"), Version: 7},
			}},
		},
		brSsmRsp: []*ssm.GetParametersOutput{
			{Parameters: []ssmtypes.Parameter{
				{Name: aws.String("TestParm1"), Value: aws.String("staleParm1"), Version: 1},
			}},
		},
		expSecrets: map[string]string{"TestSecret1": "secret1", "TestParm1": "parm1"},
		perms:      "420",
	}

	dir := t.TempDir()
	svr := newServerWithMocks(&tst, false, nil)
	req := buildMountReq(t, dir, tst, []*v1alpha1.ObjectVersion{})

	rsp, err := svr.Mount(context.Background(), req)
	if err != nil {
		t.Fatalf("%s: Got unexpected error: %s", tst.testName, err)
	}

	validateMounts(t, req.TargetPath, tst, rsp)

	expVersions := map[string]string{"TestSecret1": "primaryVersion", "TestParm1": "7"}
	for _, ver := range rsp.ObjectVersion {
		exp, ok := expVersions[ver.Id]
		if !ok {
			t.Fatalf("%s: Got unexpected object version %s", tst.testName, ver.Id)
		}
		if ver.Version != exp {
			t.Errorf("%s: Expected %s version %s got %s", tst.testName, ver.Id, exp, ver.Version)
		}
		delete(expVersions, ver.Id)
	}
	if len(expVersions) != 0 {
		t.Errorf("%s: Missing object versions %v", tst.testName, expVersions)
	}
}
