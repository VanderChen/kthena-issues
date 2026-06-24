# Proposal: Harden RoleDeleting recovery after Pod eviction

## Branch

- Clean worktree: `/Users/vanderchen/workspace/dev/kthena-workspace/kthena-fix-010-role-deleting-recovery-hardening`
- Branch: `fix/010-role-deleting-recovery-hardening`
- Base branch: `main`

The primary `kthena/` worktree currently has unrelated local modifications on
`fix/009-role-currentready-recovery`, so this task uses a separate clean
worktree to avoid disturbing those changes.

## Field Evidence

The elected controller leader observed a missing worker Pod in a Role:

```text
17:04:10.630 manageRoleReplicas: role prefill/prefill-1 in ServingGroup my-model-serving-test5-0 is missing pods (1/2), recreating
```

Nine milliseconds later, the same Role entered deletion:

```text
17:04:10.639 Role prefill/prefill-1 in ServingGroup my-model-serving-test5-0 is now Deleting
```

Earlier child delete events were ignored because the ModelServing informer cache
did not return the parent at event handling time:

```text
ModelServing of deleted pod: my-model-serving-test5-0-prefill-1-1 not found, might be already deleted
```

The controller-manager deployment had two Pods, but both logs showed
`leader-elect=true`; only one Pod acquired
`kube-system/lease.kthena.controller-manager` and started the ModelServing
controller. The second Pod only served webhooks. This makes failed leader
election unlikely.

## Code Analysis

Key paths in `pkg/model-serving-controller/controller/model_serving_controller.go`
from the clean `main` branch:

- `deletePod` calls `getModelServingAndResourceDetails`; if the parent
  ModelServing is missing from the informer cache, it logs and returns. The
  delete event is not requeued or retried.
- `manageRoleReplicas` sees a non-deleting Role with fewer Pods than expected
  and calls `CreatePodsByRole`, even when `recoveryPolicy=RoleRecreate`.
- `DeleteRole` marks the Role as `RoleDeleting` and deletes Pods/Services, but
  only removes the Role from the store if `isRoleDeleted` is true immediately.
  If the informer cache still shows Pods or Services, it does not schedule an
  explicit follow-up reconcile unless a later event happens to enqueue one.
- `isRoleDeleted` relies only on informer indexes for Pods and Services. A
  stale cache entry, missed delete event, or leftover same-label object can keep
  the Role in `RoleDeleting`.
- `createPod` treats `AlreadyExists` as success when the lister sees an
  existing Pod owned by the current ModelServing, without checking whether that
  Pod is terminating, failed, or otherwise unusable.

This design makes RoleDeleting convergence dependent on informer event ordering
and cache freshness. The failure mode is consistent with a Role that enters
`RoleDeleting`, never reaches store deletion, and is then skipped by later
`manageRoleReplicas` passes.

## Proposed Fix

Use informer caches as the normal path, but add narrow self-healing paths where
the cache view is known to be risky.

### 1. Do not drop child delete events on parent lister miss

When a Pod or Service delete event has ModelServing labels but
`modelServingLister` returns NotFound:

- enqueue the parent ModelServing key after a short delay so the cache can catch
  up;
- optionally perform one live GET for the parent ModelServing and continue
  processing if the live object exists and the child owner UID matches.

This is a single-object live GET only on the exceptional delete-event path.

### 2. Make RoleDeleting self-driven

After `DeleteRole` successfully issues Pod/Service deletion, always enqueue the
ModelServing after a short delay, even when `isRoleDeleted` is false
immediately.

On the next reconcile, `handleDeletionInProgress` should keep checking whether
the Role is fully deleted and should enqueue again with bounded backoff while
deletion is still in progress. This avoids relying solely on follow-up delete
events.

### 3. Add narrow live fallback for stuck RoleDeleting

If a Role has been `RoleDeleting` for more than a small threshold, or after a
bounded number of cache-only checks, list live Pods and Services with a selector
scoped to:

```text
namespace
modelserving.volcano.sh/group-name=<group>
modelserving.volcano.sh/role=<role>
modelserving.volcano.sh/role-id=<roleID>
```

If the live API confirms no matching Pods or Services remain, delete the Role
from the store and enqueue the ModelServing. This is not a broad namespace scan;
it is a targeted selector query for one logical Role instance.

### 4. Avoid create/delete conflict for RoleRecreate missing Pods

When `recoveryPolicy=RoleRecreate` and an existing Role has fewer Pods than
expected, prefer entering the Role deletion/recreate flow instead of first
calling `CreatePodsByRole` for the missing Pod. That keeps the behavior aligned
with RoleRecreate semantics and avoids the observed interleaving where the
controller tries to recreate and delete the same Role in one window.

### 5. Harden `createPod` conflict handling

On `AlreadyExists`, perform a live GET for the single Pod name and distinguish:

- owner UID mismatch: delete or schedule orphan cleanup;
- `DeletionTimestamp != nil`: requeue after a short delay;
- failed/evicted Pod: route into the configured recovery path;
- current owner and healthy enough: treat as already present.

This live GET is only on API create conflict.

## API Server Pressure

The proposal keeps the fast path cache-only. Live API calls are limited to:

- one GET when a child delete event cannot resolve its parent from cache;
- one targeted Pod GET after `AlreadyExists`;
- targeted Pod/Service list only for Roles stuck in `RoleDeleting`, with delay
  and bounded retry/backoff.

No full-namespace or all-ModelServing live scans are required.

## Reproduction Plan

### Manual shape A: RoleDeleting stuck by residual same-label object

In a test namespace:

1. Deploy a ModelServing using `recoveryPolicy=RoleRecreate`.
2. Delete one worker Pod in a Role.
3. After the Role enters `RoleDeleting`, create a residual Service or Pod with
   labels matching the same `group/role/roleID` but not owned by the current
   ModelServing.
4. Observe whether the current controller keeps the Role in `RoleDeleting` and
   skips recreation.

This models informer/index state that says the Role is not fully deleted even
though the desired recovery should make progress.

### Manual shape B: parent cache miss on child delete

Restart the controller-manager and delete a child Pod while caches are warming:

```bash
kubectl rollout restart deploy/kthena-controller-manager -n kube-system
kubectl delete pod -n default <modelserving>-0-prefill-1-1 --wait=false
```

Expected current failure signal if the timing hits:

```text
ModelServing of deleted pod: ... not found, might be already deleted
```

This should be covered deterministically by a unit test even if manual timing is
hard to reproduce.

## Expected Tests

Add focused controller tests under:

```text
pkg/model-serving-controller/controller/model_serving_controller_test.go
```

Planned cases:

- Pod delete event with ModelServing lister miss enqueues or recovers via live
  GET instead of being dropped.
- `DeleteRole` schedules follow-up reconcile when cache still observes role
  Pods/Services.
- Stuck `RoleDeleting` performs a targeted live check and deletes the store Role
  when live state proves cleanup is complete.
- `RoleRecreate` missing-Pod path enters role deletion/recreate instead of
  local partial Pod creation.
- `createPod` `AlreadyExists` on terminating or failed Pod requeues or routes to
  recovery instead of returning success.

Verification commands after implementation:

```bash
go test ./pkg/model-serving-controller/controller -run 'Test.*RoleDeleting|Test.*DeletePod|Test.*AlreadyExists'
go test ./pkg/model-serving-controller/controller
go test ./...
```

## Approval Gate

Proposal approved by the user. Implementation started on branch
`fix/010-role-deleting-recovery-hardening`.

## Implementation

Changed:

- `pkg/model-serving-controller/controller/model_serving_controller.go`
- `pkg/model-serving-controller/controller/model_serving_controller_test.go`

Code commit:

```text
4a8a7588 fix model serving role deletion recovery
```

Implemented hardening:

- Pod/Service delete events no longer get dropped when the parent
  ModelServing is temporarily missing from the informer cache. If the child
  resource still has the ModelServing label, the controller requeues that
  ModelServing key after a short delay.
- `RoleDeleting` is now self-driven: `DeleteRole` and later reconcile paths
  keep requeueing until the Role is removed from the store or live state proves
  deletion has completed.
- Added a narrow live fallback for stuck `RoleDeleting`: after cache-only
  checks, the controller performs targeted live Pod/Service list calls scoped
  by `group/role/roleID` and only treats the Role as deleted when no live
  resources owned by the current ModelServing remain.
- `RoleRecreate` missing-Pod recovery now deletes the whole Role only when the
  store Role is already `RoleRunning`. If the Role is still `RoleCreating`, the
  controller treats it as normal partial creation and continues creating the
  missing Pods.
- `createPod` `AlreadyExists` handling now uses a live Pod GET and distinguishes
  old-owner, deleting, failed, and healthy current-owner Pods.
- Added nil workqueue guards for enqueue helpers used by tests and exceptional
  paths.
- Fixed an existing test lifecycle issue in
  `TestModelServingControllerModelServingLifecycle` by using a cancellable
  controller context, preventing background workers from leaking into later
  tests.

## Regression Tests

Added focused coverage for:

- `TestDeletePodParentListerMissRequeuesByLabel`
- `TestCreatePodAlreadyExistsDeletingOwnedPodRequeues`
- `TestManageRoleReplicasRoleRecreateMissingPodsDeletesRole`
- `TestManageRoleReplicasRoleRecreateCreatingRoleCompletesPods`
- `TestReconcileDeletingRoleUsesLiveCheckWhenInformerIsStale`

Adjusted `TestManageRoleReplicas` to keep the old partial Pod recreation
assertions under `recoveryPolicy=None`, while the new dedicated test covers
`RoleRecreate` deleting the full Role.

## Verification Results

Passed:

```bash
go test ./pkg/model-serving-controller/controller -run 'TestCreatePodAlreadyExistsRequeues|TestCreatePodAlreadyExistsDeletingOwnedPodRequeues|TestDeletePodParentListerMissRequeuesByLabel|TestManageRoleReplicasRoleRecreateMissingPodsDeletesRole|TestReconcileDeletingRoleUsesLiveCheckWhenInformerIsStale|TestIsRoleDeleted|TestDeleteRoleRollbackOnFailure'
go test ./pkg/model-serving-controller/controller
go test ./pkg/model-serving-controller/...
```

Attempted full gate with host Go environment:

```bash
go test ./...
```

Result: failed outside the changed package set:

- `pkg/model-booster-controller/controller TestReconcile` did not create the
  expected AutoscalingPolicy/ModelServing/ModelServer/ModelRoute resources and
  then panicked on an empty slice.
- e2e packages failed during Helm install because existing cluster CRDs conflict
  with Helm apply ownership/field manager state:
  `conflict with "kubectl": .spec.versions`.

The relevant ModelServing controller package and package family passed.

## Kind Verification

Date: 2026-06-23

Built and deployed controller-manager from branch
`fix/010-role-deleting-recovery-hardening`:

```bash
GOOS=linux GOARCH=arm64 go build \
  -o /Users/vanderchen/workspace/dev/kthena-workspace/local-output/kthena-controller-manager-010 \
  ./cmd/kthena-controller-manager/main.go

docker build -t kthena-controller-manager:dev-010-role-deleting-recovery-hardening \
  -f Dockerfile.local \
  --build-arg BINARY_DIR=local-output \
  --build-arg BINARY_NAME=kthena-controller-manager-010 .

kind load docker-image kthena-controller-manager:dev-010-role-deleting-recovery-hardening --name kind

helm upgrade --install kthena ./charts/kthena \
  --namespace kthena-system \
  --create-namespace \
  --set workload.controllerManager.evictionWebhook.enabled=true \
  --set workload.controllerManager.image.repository=kthena-controller-manager \
  --set workload.controllerManager.image.tag=dev-010-role-deleting-recovery-hardening \
  --set workload.controllerManager.image.pullPolicy=IfNotPresent
```

Deployment verified:

```text
kthena-controller-manager:dev-010-role-deleting-recovery-hardening
deployment "kthena-controller-manager" successfully rolled out
```

Applied reproduction workload:

```text
issues/bugs/010-role-deleting-recovery-hardening-IP/kind-role-recreate-e2e.yaml
```

Initial Pod UIDs:

```text
role-recreate-e2e-010-0-prefill-0-0   581ca622-54f7-422f-93ec-68e510aecac0
role-recreate-e2e-010-0-prefill-0-1   07f742a5-337d-4ea2-9386-9466a186ad29
```

Action:

```bash
kubectl delete pod role-recreate-e2e-010-0-prefill-0-1 -n kthena-e2e-010 --wait=false
```

Recovered Pod UIDs:

```text
role-recreate-e2e-010-0-prefill-0-0   90a3f07e-da0d-47c6-bf31-c7dfec9410f2
role-recreate-e2e-010-0-prefill-0-1   a5ef6fb7-1213-4261-915c-b5368888855a
```

The worker delete caused the entry Pod to be deleted too, and both Pods were
recreated with new UIDs, confirming Role-level recreation.

Controller log evidence:

```text
Role prefill/prefill-0 in ServingGroup role-recreate-e2e-010-0 is now Deleting
role prefill-0 of servingGroup role-recreate-e2e-010-0 has been deleted
manageRoleReplicas: scaling UP role prefill in ServingGroup role-recreate-e2e-010-0: current=0, expected=1
Role prefill/prefill-0 in ServingGroup role-recreate-e2e-010-0 is now Creating
Role prefill/prefill-0 in ServingGroup role-recreate-e2e-010-0 is now Running
```

Final status:

```text
NAME                    AVAILABLE   CURRENT   UPDATED   AVAILABLE_COND
role-recreate-e2e-010   1           1         1         True
```

Cleanup:

```bash
kubectl delete namespace kthena-e2e-010 --wait=true --timeout=120s
```

## Follow-up: Periodic Global Reconcile

Date: 2026-06-24

Additional field signal: long-running stability tests that repeatedly scale
ModelServing replicas up and down can also occasionally leave a Pod missing.
Restarting the controller-manager fixes the state because startup runs
`syncAll()`, which reprocesses cached child Pods and enqueues every
ModelServing.

Code commit:

```text
016aa89b fix model serving periodic recovery sync
```

The controller previously only ran this global cache-based check once at
startup. Informer resync periods are set to `0`, so a missed or dropped event
chain during repeated scaling had no periodic self-healing path.

Added a low-frequency periodic full sync:

- default period: `5m`;
- data source: local informer cache via existing listers;
- behavior: reprocess cached Pods and enqueue all ModelServings, matching
  startup `syncAll()`;
- apiserver pressure: no periodic live list calls are introduced. The apiserver
  is only touched by normal reconcile work for objects that actually need
  correction.

Additional test:

- `TestPeriodicFullSyncRequeuesModelServing`

Verification:

```bash
go test ./pkg/model-serving-controller/controller -run 'TestPeriodicFullSyncRequeuesModelServing|TestManageRoleReplicasRoleRecreateMissingPodsDeletesRole|TestManageRoleReplicasRoleRecreateCreatingRoleCompletesPods|TestReconcileDeletingRoleUsesLiveCheckWhenInformerIsStale' -count=1 -v
go test ./pkg/model-serving-controller/...
```
