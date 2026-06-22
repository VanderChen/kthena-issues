# Feature Proposal & Implementation

## Design
Enable per-pod DNS resolution for `ModelServing` workloads by setting `hostname` and `subdomain` on Pods and updating the headless service selector to include all pods in a role replica.

1.  **Pod Specification Update:** Set `spec.hostname` to the pod's name and `spec.subdomain` to the headless service's name for all pods (entry and workers).
2.  **Service Selector Update:** Update the headless service selector to include all pods in the role replica by removing the `EntryLabelKey: "true"` filter.
3.  **Panic Fix:** Added a check for `OwnerReferences` length in `manageRoleReplicas` to prevent a panic when encountering pods with no owner references.

## Implementation Details
- Component changes:
    - `kthena/pkg/model-serving-controller/utils/utils.go`: Updated `GenerateEntryPod` and `GenerateWorkerPod` to set `Hostname` and `Subdomain`.
    - `kthena/pkg/model-serving-controller/controller/model_serving_controller.go`: 
        - Updated `manageHeadlessService` to remove `EntryLabelKey` from the headless service selector.
        - Fixed a potential panic in `manageRoleReplicas` when `pod.OwnerReferences` is empty.
    - `kthena/pkg/model-serving-controller/controller/model_serving_controller_test.go`: Updated `TestManageHeadlessService` to match the new selector logic.
    - `kthena/pkg/model-serving-controller/utils/utils_test.go`: Added `TestGeneratePod_HostnameSubdomain` to verify `Hostname` and `Subdomain` settings.
- Dependencies added: None

## Verification Results
- Unit Tests: All unit tests passed, including new tests for `Hostname`/`Subdomain` and updated tests for headless service management.
- E2E Tests: Manual verification performed in Kind cluster (automated E2E tests had setup conflicts in the environment).
- Manual Verification:
    - Deployed sample `ModelServing` with workers.
    - Verified `hostname` and `subdomain` are correctly set on pods.
    - Verified headless service selector includes all pods in the role replica.
    - Verified DNS resolution using `curl` between pods: `sample-0-prefill-0-1.sample-0-prefill-0-0` resolved correctly.

## Associated Commits
- Commit ID: ba2e9bdd27fb0d9240c96f6c3fdef452ca234bdc
- Branch: feat/002-headless-svc
