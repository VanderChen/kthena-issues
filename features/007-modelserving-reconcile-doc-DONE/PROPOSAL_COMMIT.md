# Feature Proposal & Implementation

## Design
Add a developer-facing reconcile walkthrough for the current `ModelServing`
controller implementation.

Recommended target:

- Primary target: `kthena/pkg/model-serving-controller/README.md`
- If the README becomes too large, use:
  `kthena/pkg/model-serving-controller/RECONCILE_FLOW.md` and link it from the
  README.

The document will be written for developers who need to change controller code,
not for end users authoring CR manifests. It will therefore explain the runtime
state machine and point to concrete code locations.

## Proposed Document Structure
1. Component scope and resource model
   - `ModelServing` spec/status fields.
   - ServingGroup, Role, entry pod, worker pods, headless Service, PodGroup.
   - Labels used to relate child resources back to a `ModelServing`.

2. Controller setup and event sources
   - Informers for `ModelServing`, Pods, Services, and optional PodGroups.
   - Indexed lookups by group and role.
   - Workqueue enqueue paths.

3. Main reconcile sequence
   - `syncModelServing` order:
     1. compute revision from role templates after removing role replica counts;
     2. manage ServingGroup replica count;
     3. manage Role replica count inside every ServingGroup;
     4. manage rolling update deletion;
     5. reconcile headless Services;
     6. update `ModelServing.status`.

4. In-memory datastore model
   - ServingGroup and Role status values.
   - Running pod tracking.
   - How startup `syncAll` rebuilds the store from existing pods.
   - Why store state is reconciled from child events.

5. Create and scale-up flow
   - ServingGroup creation by ordinal.
   - PodGroup create/update before pod creation.
   - Role replica creation and entry/worker pod naming.
   - Where pod labels, annotations, env vars, owner refs, revision labels, and
     role template hashes are attached before plugin hooks run.

6. Plugin hook intervention flow
   - `buildPluginChain` constructs a chain from `ms.Spec.Plugins`.
   - `CreatePodsByRole` calls `createPod` for entry and worker pods.
   - `createPod` invokes `chain.OnPodCreate` before the Pod is submitted to the
     Kubernetes API server, allowing plugins to mutate or validate generated
     pods.
   - `handleReadyPod` invokes `chain.OnPodReady` before updating datastore role
     and ServingGroup readiness state.
   - `plugins.HookRequest` fields to explain: `ModelServing`, `ServingGroup`,
     `RoleName`, `RoleID`, `IsEntry`, and `Pod`.
   - Current built-in flow to cover: plugin registry, chain ordering, plugin
     scope matching, demo plugin behavior, and LWS labels plugin behavior.
   - Clarify that plugin failures abort the current hook path and therefore can
     affect pod creation or readiness handling.

7. Scale-down and deletion ordering
   - ServingGroup scale-down.
   - Role scale-down.
   - Priority tuple: readiness/status, pod deletion cost, ordinal/index.
   - How `DeletionCost` protects high-value pods or groups.

8. Rolling update flow
   - Revision calculation and `ControllerRevision` persistence.
   - `ServingGroupRollingUpdate`: delete outdated ServingGroups.
   - `RoleRollingUpdate`: delete outdated Roles and update group revision when
     roles match the new template.
   - `maxUnavailable` availability gate.
   - `partition` protection and recovery of protected ordinals from old
     ControllerRevision data.

9. Failure and recovery flow
   - Ready pod event transitions Role/ServingGroup to `Running`.
   - Failed/restarted pod handling and `RestartGracePeriodSeconds`.
   - `ServingGroupRecreate` versus `RoleRecreate`.
   - Delete event completion checks and re-enqueue behavior.

10. Status calculation
   - `Replicas`, `AvailableReplicas`, `UpdatedReplicas`, `CurrentReplicas`.
   - `CurrentRevision` and `UpdateRevision` update rules.
   - Conditions and label selector used by the scale subresource.
   - ControllerRevision cleanup after revision status changes.

11. Change guide
    - Which functions/tests to read before touching rolling update, partition,
      scale-down, recovery, PodGroup, plugin, or status logic.

## Code Areas To Reference
- `pkg/model-serving-controller/controller/model_serving_controller.go`
  - Controller construction, handlers, workqueue, `syncModelServing`.
  - ServingGroup/Role replica management.
  - rolling update, deletion, recovery, headless service, and status logic.
- `pkg/model-serving-controller/controller/binpack_scaledown.go`
  - readiness and pod deletion-cost based deletion scoring.
- `pkg/model-serving-controller/datastore/store.go`
  - in-memory ServingGroup/Role state.
- `pkg/model-serving-controller/utils/controller_revision.go`
  - `ControllerRevision` create/get/cleanup helpers.
- `pkg/model-serving-controller/utils/utils.go`
  - child resource naming, labels, pod generation, status conditions, and
    `maxUnavailable` helpers.
- `pkg/apis/workload/v1alpha1/model_serving_types.go`
  - public spec/status fields for rollout, recovery, and scale status.
- `pkg/model-serving-controller/podgroupmanager/manager.go`
  - PodGroup lifecycle integration.
- `pkg/model-serving-controller/plugins/*.go`
  - plugin registry, chain construction, scope matching, hook request data, and
    built-in hook behavior.
- Existing controller tests under `pkg/model-serving-controller/controller/*_test.go`
  for partition, rolling update, scale-down, and recovery behavior.

## Implementation Details
- New APIs/CRDs: none.
- Component changes:
  - Added `kthena/pkg/model-serving-controller/RECONCILE_FLOW.md`.
  - Linked the new walkthrough from
    `kthena/pkg/model-serving-controller/README.md`.
- Dependencies added: none.
- Behavioral changes: none.
- Generated code: not required.

## Verification Plan
- Run a documentation-only review for accuracy against current code.
- Run `git diff --check` to catch whitespace issues.
- No Go tests are required for the proposal stage or documentation-only changes,
  but if implementation touches code unexpectedly, run `go test ./...` from
  `kthena/` before marking the task done.

## Verification Results
- Unit Tests: not run; documentation-only change.
- E2E Tests: not run; documentation-only change.
- Manual Verification:
  - Inspected current controller code paths and API types.
  - Inspected plugin registry, chain, scope filtering, and built-in hooks.
  - Added reconcile walkthrough covering the main sequence, plugin hook flow,
    rolling update, partition, ControllerRevision, scale-down ordering,
    PodGroup integration, recovery, headless Services, and status calculation.
  - Added Mermaid diagrams for resource topology, main reconcile flow, plugin
    hook flow, scale-down ordering, rolling update decisions, and recovery
    states.
  - Ran `git -C kthena diff --check`; passed.

## Associated Commits
- Commit ID: 653e505a
- Branch: `feat/007-modelserving-reconcile-doc`
