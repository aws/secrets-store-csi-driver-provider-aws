---
name: Bug report
about: Create a report to help us improve
title: ''
labels: bug
assignees: ''

---

**Describe the bug**


**To Reproduce**

Steps to reproduce the behavior:


Do you also notice this bug when using a different secrets store provider (Vault/Azure/GCP...)? **Yes/No**

If yes, the issue is likely with the k8s Secrets Store CSI driver, not the AWS provider. Open an issue in [that repo](https://github.com/kubernetes-sigs/secrets-store-csi-driver/issues).

**Expected behavior**

**Environment:**
OS, Go version, CSI driver and AWS Provider versions, etc.

- [ ] I am able to reproduce this issue on the latest version of the CSI driver and AWS providers.

**Additional context**
Add any other context about the problem here.
