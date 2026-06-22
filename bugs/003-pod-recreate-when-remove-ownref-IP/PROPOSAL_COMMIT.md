# Proposal: Fix Pod Recreate using StatefulSet-style Orphan Cleanup

## Bug Analysis
The controller uses deterministic Pod names (e.g., `sample-0-prefill-0-0`). However, it currently filters out Pods that lack a valid `OwnerReference` from its Informer. When a "zombie" Pod exists (same name, correct labels, but no OwnerRef), the controller:
1. Cannot "see" it via the Informer.
2. Thinks the replica is missing.
3. Tries to create it, but fails with `AlreadyExists` from the API Server.
4. Fails to delete the zombie Pod because it's invisible to the sync loop.

## Solution Plan: "Deterministic Identity + Active Correction"
We will follow the `StatefulSet` pattern: maintain stable names but proactively delete any Pod that occupies the name without the correct ownership.

### 1. Broaden Informer Vision
Modify the Pod Informer's `FilterFunc` to include Pods that have the correct `ModelServing` labels (`modelserving.volcano.sh/name`), even if the `OwnerReference` is missing or incorrect. This allows the controller to "see" and manage orphaned Pods.

### 2. Proactive Orphan Cleanup
In `manageRoleReplicas`, when checking existing Pods for a specific role and index:
- If a Pod is found, verify its ownership using `utils.IsOwnedByModelServingWithUID(pod, ms.UID)`.
- If ownership is invalid (missing OwnerRef or UID mismatch), **explicitly delete the Pod**.
- Re-enqueue the `ModelServing` resource.

### 3. Conflict Resolution in Create
In `createPod`, if an `AlreadyExists` error occurs, attempt to fetch the existing Pod again. If it's still not owned by the current `ModelServing`, delete it immediately.

## Implementation Details
- **File**: `kthena/pkg/model-serving-controller/controller/model_serving_controller.go`
    - Update `isOwnedByModelServing` or the `NewModelServingController` filter logic to be label-aware.
    - Update `manageRoleReplicas` (around line 1080) to delete pods that fail the `IsOwnedByModelServingWithUID` check.
    - Update `createPod` (around line 2000) to delete pods on `AlreadyExists` if ownership is wrong.

## Verification
- Run `reproduce-v2.sh`: 
    1. The manually created orphaned pod (same name, no OwnerRef) should be detected.
    2. The controller should delete the orphaned pod.
    3. The controller should successfully create a new Pod with the correct `OwnerReference`.
