package server

import (
	"context"
	"testing"

	"sigs.k8s.io/secrets-store-csi-driver/provider/v1alpha1"
)

func FuzzMountAttributes(f *testing.F) {
	f.Add(`{"csi.storage.k8s.io/pod.name":"pod","csi.storage.k8s.io/pod.namespace":"ns","csi.storage.k8s.io/serviceAccount.name":"sa","region":"us-west-2","objects":"- objectName: s1\n  objectType: secretsmanager"}`, "/mnt", "420")
	f.Add(`{}`, "/mnt", "420")
	f.Add(`not json`, "/mnt", "420")
	f.Add(`{"region":"us-west-2"}`, "/mnt", "")
	f.Add(`{"region":"us-west-2"}`, "", "420")
	f.Add(`{"region":"us-west-2","failoverRegion":"us-east-1"}`, "/mnt", "420")
	f.Add(`{"usePodIdentity":"invalid"}`, "/mnt", "420")
	f.Add(`{"preferredAddressType":"invalid"}`, "/mnt", "420")

	f.Fuzz(func(t *testing.T, attributes, targetPath, permission string) {
		svr := newServerWithMocks(&testCase{
			attributes: map[string]string{
				"namespace": "fakeNS", "accName": "fakeSvcAcc", "podName": "fakePod",
				"nodeName": "fakeNode", "region": "fakeRegion", "roleARN": "fakeRole",
			},
		}, true, nil)

		req := &v1alpha1.MountRequest{
			Attributes:           attributes,
			TargetPath:           targetPath,
			Permission:           permission,
			CurrentObjectVersion: []*v1alpha1.ObjectVersion{},
		}
		svr.Mount(context.Background(), req)
	})
}
