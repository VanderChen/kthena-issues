# Proposal: ModelServing Headless Service Lifecycle Plugin

## Status

DONE. The `pod-ranktable-plugin` runtime dependency alignment is implemented,
verified, committed, and pushed: Kubernetes clients and listers are supplied
through `HookRequest`, not plugin factory dependencies.

Target implementation branch:

```text
feat/011-modelserving-headless-service-opt-in
```

The branch initially contained the superseded implementation commit:

```text
ab2cd1548238bf424ff379676d279fc97a3d9638
```

That commit was dropped from the final branch history. The revised signed-off
implementation, including the unified `HookRequest` and `Plugin` lifecycle
contract, is represented by the single commit:

```text
5c522864b1c1db10a248460539b570c04909afd9
```

## Revised Design Decisions

1. There is no dedicated Headless Service field in `ModelServingSpec`.
2. Users opt in through the existing `spec.plugins` API with the built-in
   plugin name `headless-service`.
3. The plugin owns the complete lifecycle of its Services through narrow hooks
   attached to existing Role creation/reconciliation and deletion paths.
4. Services are auxiliary resources and are never used to decide whether a
   ServingGroup or Role still exists.
5. There is no ModelServing-wide reconcile hook. The existing `HookRequest` and
   `Plugin` interface are extended with Role lifecycle context and hooks, so
   future lifecycle implementations use one stable plugin contract rather than
   capability-specific request and interface types.

## Current Coupling to Remove

The controller currently couples Headless Services to its core state machine in
the following places:

- `syncModelServing` directly calls `manageHeadlessService`.
- `manageHeadlessService` and `cleanupHeadlessServices` implement Service
  desired state in the controller package.
- `DeleteRole` and `deleteServingGroup` directly list and delete Services.
- `isServingGroupDeleted` waits for Pods, PodGroups, and Services to disappear.
- `isRoleDeleted` waits for Pods and Services to disappear.
- the Service informer delete handler re-enqueues a ModelServing so a missing
  Service can be recreated.

The Service informer can remain as plugin-runtime infrastructure, but the core
controller must no longer interpret a Service as ServingGroup/Role state.

## User-facing API

The existing generic plugin API is sufficient; no new ModelServing API field is
required:

```yaml
spec:
  plugins:
    - name: headless-service
      type: BuiltIn
```

Default behavior:

| Plugin configuration | Desired Headless Services |
| --- | --- |
| no `headless-service` entry | none |
| one `headless-service` entry | one per active Role replica whose Role has a `workerTemplate` |

The first version has no plugin-specific config. `scope.roles` may restrict the
plugin to named Roles. `scope.target` is Pod-specific and therefore must be
omitted or set to `All` for this lifecycle plugin; `Entry` or `Worker` is
rejected during plugin construction rather than silently misinterpreted.

Duplicate `headless-service` entries are rejected because two instances cannot
independently own the same Service names.

## Plugin Framework Extension

### Unified lifecycle interface

`ReconcileModelServing` is not an existing controller call point and is too
broad for this feature. Extend the existing request and interface directly:

```go
type HookRequest struct {
    ModelServing *workloadv1alpha1.ModelServing
    ServingGroup string
    RoleName     string
    RoleID       string
    RoleIndex    int
    Role         *workloadv1alpha1.Role
    IsEntry      bool
    Pod          *corev1.Pod
    KubeClient    kubernetes.Interface
    ServiceLister corelisters.ServiceLister
}

type Plugin interface {
    Name() string
    OnPodCreate(context.Context, *HookRequest) error
    OnPodReady(context.Context, *HookRequest) error
    OnRoleSync(context.Context, *HookRequest) error
    OnRoleDelete(context.Context, *HookRequest) error
}
```

`demo-pod-tweaks` and `lws-standard-labels` implement no-op Role hooks. The
Headless Service plugin reuses `OnPodCreate` for initial creation and implements
the Role hooks for recovery and deletion. A single request type keeps common
ModelServing, ServingGroup, and Role context available as additional lifecycle
hooks are added later; hook-specific fields such as `Pod` may be nil when they
do not apply.

Following the `pod-ranktable-plugin` branch pattern, the plugin factory receives
only `PluginSpec`. The Kubernetes client and cache-backed Service lister are
provided on each `HookRequest`. This keeps plugin construction configuration-only
and makes runtime controller resources available uniformly to future lifecycle
plugins without introducing a separate dependency container. The hook request
does not expose the controller datastore or add resource fields to
`ModelServingSpec`.

### Hook placement

Hooks are inserted into the controller's existing Role lifecycle logic:

| Existing call path | Hook | Purpose |
| --- | --- | --- |
| existing `OnPodCreate` call in `createPod`, for an entry Pod | `OnPodCreate` | create the Role's Service during the current Pod creation flow |
| active Role loop in `manageRoleReplicas` | `OnRoleSync` | idempotently ensure resources and recover a deleted Service after the existing Service event re-enqueues the ModelServing |
| `DeleteRole`, after the Role's Pod delete request succeeds | `OnRoleDelete` | issue deletion for resources owned by that Role |
| `deleteServingGroup`, after the group-wide Pod delete request succeeds | `OnRoleDelete` for every stored Role in the group | reuse the same cleanup hook because this path does not call `DeleteRole` |

Initial creation therefore uses an existing plugin hook. `OnRoleSync` is the
only steady-state hook added: it is Role-scoped and runs inside the existing
per-Role management loop, not as a renamed ModelServing-wide reconcile hook. It
must be idempotent. `OnRoleDelete` only requires a successful delete request;
the core controller does not wait for the Service object to disappear.

## Headless Service Plugin Hooks

The built-in `headless-service` plugin implements the narrow hooks as follows:

1. The existing `OnPodCreate` hook handles entry Pods only. It returns when the
   Role is out of scope or has no `workerTemplate`; otherwise it creates the
   corresponding Service idempotently before the entry Pod API create.
2. `OnRoleSync` applies the same ensure operation through the Role-ID Service
   index, covering controller restarts and accidental Service deletion.
3. `OnRoleDelete` finds the Service for that Role ID and issues an idempotent
   delete only when it is controlled by the current ModelServing UID.
4. The existing Service delete handler remains lightweight: it enqueues the
   owning ModelServing. The next `manageRoleReplicas` pass invokes
   `OnRoleSync`, which recreates the Service only if the Role and plugin still
   exist.

Removing the plugin from `spec.plugins` stops creation and recovery but does not
trigger immediate Service cleanup. Existing Services remain owned by the
ModelServing and are deleted by `OnRoleDelete` when their corresponding Roles
are deleted. Role-delete cleanup is independent of the plugin's current
presence and scope so historical Services are not leaked. No plugin finalizer
or plugin-removal hook is introduced.

New Services receive a plugin identity label so ownership is explicit. For
migration, an owned Service is also recognized as legacy plugin output when it
has all of the existing ModelServing/group/role/role-ID labels,
`clusterIP: None`, and the current ModelServing controller owner UID. This
strict fallback avoids deleting arbitrary user Services.

Create/Delete `AlreadyExists`/`NotFound` races are handled idempotently. Other
errors fail the containing Role lifecycle operation and trigger the normal
workqueue retry.

## Core Deletion Semantics

Core controller changes are explicit:

- `isServingGroupDeleted` returns true when no matching Pods and no matching
  PodGroups remain; Services are not queried.
- `isRoleDeleted` returns true when no matching Pods remain; Services are not
  queried.
- `DeleteRole` stops containing Service-specific logic and invokes the generic
  `OnRoleDelete` hook.
- `deleteServingGroup` stops containing Service-specific logic and invokes the
  same generic `OnRoleDelete` hook for each Role it is already deleting.
- the old `manageHeadlessService` and `cleanupHeadlessServices` controller
  methods are removed.

Therefore a Service that accepted deletion but remains terminating cannot hold
a ServingGroup/Role in the controller datastore. An API request failure is
still returned so normal reconciliation retries can guarantee cleanup.

## Compatibility Integrations

- Remove `EnableHeadlessService` from the API type and regenerate CRDs,
  apply-configurations, DeepCopy output, and reference documentation.
- ModelBooster conversion appends `headless-service` when any generated Role
  has worker replicas, preserving its `ENTRY_ADDRESS` contract.
- LeaderWorkerSet conversion appends `headless-service` when the generated Role
  has workers, alongside `lws-standard-labels`.
- Multi-node and data-parallel examples replace
  `enableHeadlessService: true` with the plugin entry.
- Documentation describes the plugin as the only opt-in mechanism.

The superseded boolean was not present on upstream `main`, so removing it does
not alter an upstream released API. Users of the intermediate feature branch
must migrate to the plugin entry.

## Implementation Scope

Expected areas:

```text
pkg/apis/workload/v1alpha1/model_serving_types.go
pkg/model-serving-controller/plugins/
pkg/model-serving-controller/controller/model_serving_controller.go
pkg/model-serving-controller/controller/model_serving_controller_test.go
pkg/model-serving-controller/controller/lws_controller.go
pkg/model-booster-controller/convert/
charts/kthena/charts/workload/crds/
client-go/applyconfiguration/
docs/kthena/docs/
examples/model-serving/
test/e2e/controller-manager/
```

No new external dependency is required. Generated files will be updated only
through `make generate`.

## Test Plan

### Plugin manager tests

- unified dispatch for Pod and Role lifecycle hooks through `Plugin` and
  `HookRequest`;
- existing plugin ordering and scope behavior remains stable;
- `OnRoleSync` and `OnRoleDelete` execute only for configured plugins;
- duplicate lifecycle plugin entries and invalid target scope fail clearly;
- hook errors propagate to reconciliation.

### Headless Service plugin tests

- absent plugin creates zero Services;
- enabled plugin creates the same Services as the old behavior;
- `OnRoleSync` creation is idempotent and a deleted desired Service is
  recreated after the existing delete event requeues its ModelServing;
- Role scope limits desired Services;
- `OnRoleDelete` cleans Services from both Role and ServingGroup deletion paths;
- legacy owned Services are cleaned up;
- user-managed, stale-UID, non-Headless, and unrelated Services are preserved;
- API failures are returned for retry.

### Core controller tests

- a remaining Service does not block `isServingGroupDeleted`;
- a remaining Service does not block `isRoleDeleted`;
- Role and ServingGroup deletion use the generic Role delete hook and do not
  contain Service-specific deletion code;
- adding/removing the plugin does not change Role revision or recreate Pods;
- ModelBooster and LWS conversions add the plugin only when stable entry DNS is
  required.

### Regression gates

```bash
make generate
make gen-check
go test ./pkg/model-serving-controller/... ./pkg/model-booster-controller/...
go test $(go list ./... | grep -v /e2e)
make lint
```

Per workspace policy, repository E2E packages will not run unless explicitly
requested.

## Mandatory Kind Verification

Build and deploy a new `kthena-controller-manager:dev-011` image, then verify:

1. A multi-Pod ModelServing without the plugin creates no Headless Service.
2. Adding `headless-service` creates the exact desired Services without changing
   Pod UIDs.
3. Deleting one desired Service causes plugin-driven recreation.
4. Scaling down a Role or ServingGroup deletes obsolete Services.
5. A Service held in `Terminating` by a test finalizer does not prevent the
   corresponding ServingGroup/Role from completing deletion.
6. Removing the plugin stops recreation without changing Pod UIDs; existing
   Services remain until their corresponding Roles are deleted.
7. An unrelated/user-managed Service is preserved.
8. Generated ModelBooster/LWS ModelServings contain the plugin when they need
   stable entry DNS.

Record commands, YAML, resource UIDs/counts, controller logs, and observed
status transitions here before returning the task to `DONE`.

## Implementation Result

- Removed the superseded `EnableHeadlessService` API field and regenerated the
  workload CRD, apply configurations, and CRD reference documentation.
- Added the built-in `headless-service` plugin. Initial creation uses the
  existing `OnPodCreate` call; recovery and cleanup use `OnRoleSync` and
  `OnRoleDelete` on the unified `Plugin` interface.
- Added the Kubernetes client and cache-backed Service lister to `HookRequest`,
  following the runtime resource pattern in `pod-ranktable-plugin`. Plugin
  factories remain configuration-only and no controller datastore is exposed.
- Added Role-delete cleanup registration so Services created under an earlier
  plugin configuration are cleaned only when their Role is deleted, even if the
  plugin was removed or its scope changed.
- Removed core Service creation/deletion code and removed Services from
  `isRoleDeleted` and `isServingGroupDeleted`. The now-unused custom Service
  informer indexes were also removed.
- New Services carry `modelserving.volcano.sh/plugin: headless-service`.
  Cleanup additionally recognizes the complete legacy Headless Service shape,
  always requires the current ModelServing owner UID, and preserves unmanaged,
  stale-UID, and ordinary ClusterIP Services.
- ModelBooster and LeaderWorkerSet conversion add the plugin only when the
  generated Role has workers. Multi-node examples and user documentation now
  opt in through `spec.plugins`.

## Automated Verification Results

Focused packages:

```text
go test ./pkg/model-serving-controller/plugins ./pkg/model-serving-controller/controller ./pkg/model-booster-controller/convert
ok  github.com/volcano-sh/kthena/pkg/model-serving-controller/plugins
ok  github.com/volcano-sh/kthena/pkg/model-serving-controller/controller
ok  github.com/volcano-sh/kthena/pkg/model-booster-controller/convert
```

ModelServing packages after removing the obsolete Service indexes:

```text
go test ./pkg/model-serving-controller/...
ok  all ModelServing controller packages
```

Mandatory non-E2E repository gate:

```text
go test $(go list ./... | grep -v /e2e)
ok  all selected packages
```

Static and generated checks:

```text
make lint
passed

make generate
tracked diff SHA-256 before: 9384b5e5b13ca25fd5595d94a2ac1aa7f76c7195cffab47170d49a0b1c397b2f
tracked diff SHA-256 after:  9384b5e5b13ca25fd5595d94a2ac1aa7f76c7195cffab47170d49a0b1c397b2f
```

`make gen-check` was first run while the intentional implementation diff was
still uncommitted, so its final `git diff --exit-code` correctly reported that
diff. The generator itself completed, and the repeated identical diff hashes
above proved it made no further changes. It was run again after implementation
implementation commit and passed with a clean `git diff --exit-code`.

## Kind Verification Results

Environment:

```text
cluster: kind
node architecture: arm64
image: kthena-controller-manager:dev-011
image sha256:10e377aaa12e356a1e293e75dfa02c016227819c7652ac96e00081c0ac4e9a79
fixture: kind-headless-service-plugin.yaml
```

The controller was built for `linux/arm64`, loaded into all four Kind nodes,
and installed with the workload Helm subchart. Volcano was already running.

1. Default opt-out:

   - Created `feature-011/headless-plugin` with 2 ServingGroups, 2 Role replicas
     per group, and 1 worker per Role replica: 8 Pods total.
   - With no plugin, the only Service was the fixture's
     `user-managed-headless`; generated Service count was 0.

2. Opt-in without Pod restart:

   - Patched `spec.plugins` to contain `headless-service`.
   - Exactly 4 generated Headless Services appeared, one per Role replica.
   - A generated Service had `clusterIP: None`,
     `publishNotReadyAddresses: true`, the existing group/role/role-ID
     selector, the current ModelServing controller owner reference, and
     `modelserving.volcano.sh/plugin: headless-service`.
   - All 8 Pod UIDs were unchanged. Representative UIDs included entry Pod
     `headless-plugin-0-serving-0-0 = ac5124f0-b710-4b98-b672-6dda2fa77a3c`
     and worker Pod
     `headless-plugin-1-serving-1-1 = bcdeb38e-ed0a-48f7-97d8-5aa9f10d57ad`.

3. Recovery:

   - Deleted `headless-plugin-0-serving-0-0` Service.
   - Old UID: `5fb175fe-e5ff-454c-9b8d-331d85d74faf`.
   - Recreated UID: `fb0bffc5-7a28-4d14-8194-b4d8b2960ef5`.

4. Plugin removal behavior:

   - Removed `spec.plugins`; all 4 existing generated Services remained and all
     Pod UIDs were unchanged.
   - Deleted `headless-plugin-0-serving-0-0` again. Waiting 10 seconds for
     creation timed out, proving recovery stopped after plugin removal.

5. Role-delete-only cleanup and deletion decoupling:

   - Added test finalizer `feature-011.test/hold` to
     `headless-plugin-1-serving-1-0`, then scaled Role replicas from 2 to 1
     while the plugin was absent.
   - Both obsolete Role replicas' Pods were deleted. The unheld obsolete
     Service was deleted; the held Service received a deletion timestamp and
     remained `Terminating`.
   - Despite that remaining Service, ModelServing reported
     `generation=4`, `observedGeneration=4`, `replicas=2`,
     `availableReplicas=2`, `Progressing=False`, and `Available=True`.
   - Controller logs recorded both `serving-1` Roles deleted and both
     ServingGroups returning to `Running` while the Service was still held.
   - The test finalizer was then removed and the Service completed deletion.

6. Ownership isolation:

   - `user-managed-headless` remained present throughout opt-in, recovery,
     plugin removal, and Role scale-down.

7. Compatibility conversion:

   - Applied `kind-modelbooster-plugin.yaml` with `pods: 2`.
   - The generated `booster-headless-plugin-backend` ModelServing was owned by
     `ModelBooster` and contained `plugins: [headless-service]`.
   - The local cluster does not have the LeaderWorkerSet CRD installed, so LWS
     conversion was verified by the passing `lws_controller_test.go` unit test
     instead of creating an LWS object in Kind.

The isolated `feature-011` namespace, temporary finalizer, ModelBooster, and
Helm release were removed after verification.

## Unified Interface Follow-up Verification

After replacing `RoleHookRequest` and `RoleLifecyclePlugin` with the shared
`HookRequest` and `Plugin` contract, the following gates were rerun:

```text
go test ./pkg/model-serving-controller/plugins ./pkg/model-serving-controller/controller ./pkg/model-booster-controller/convert
ok  all selected packages

go test $(go list ./... | grep -v /e2e)
ok  all selected packages

make lint
passed

make generate
tracked diff SHA-256 before: 6461ca00ea55fec9d2da859ed0d9896c083407804ad8a3a392cbf1f1a25c1e56
tracked diff SHA-256 after:  6461ca00ea55fec9d2da859ed0d9896c083407804ad8a3a392cbf1f1a25c1e56

make gen-check
passed on the clean implementation commit
```

The follow-up Kind run used image
`kthena-controller-manager:dev-011-unified` with image ID
`sha256:d74dda73fcf9921199d685d0c998f8db311278e0ed54e5c16e31fcef125dd8e7`.
It confirmed:

- no generated Service before the plugin was enabled;
- enabling the plugin created 4 Services while all 8 Pod UIDs stayed unchanged;
- deleting `headless-plugin-0-serving-0-0` recreated it with UID
  `454ab9e5-237c-47dd-9a2e-ebd5499c2979`, replacing UID
  `fc21b6f8-53a6-484c-8fa6-9b7b35f0c676`;
- removing the plugin preserved existing Services and did not restart Pods;
- scaling Role replicas from 2 to 1 cleaned both `serving-1` Services through
  `OnRoleDelete` even though the plugin was no longer configured;
- deleting a remaining generated Service after plugin removal did not recreate
  it, while `user-managed-headless` remained present;
- controller logs showed both obsolete Roles reaching deleted state and no
  lifecycle hook errors.

The follow-up `feature-011` namespace and Helm release were removed after the
verification.

## HookRequest Runtime Resources Follow-up Verification

The implementation was aligned with the `pod-ranktable-plugin` branch:

- removed `Dependencies` from the plugin package;
- changed `Factory` and all built-in plugin constructors to accept only
  `PluginSpec`;
- added `KubeClient` and `ServiceLister` to the shared `HookRequest`;
- populated both fields at Pod create/ready, Role sync, and Role delete call
  points;
- changed `headless-service` to use only runtime resources from each request;
- moved missing-client validation from construction to the hooks that require
  Kubernetes API access.

Verification gates:

```text
go test ./pkg/model-serving-controller/plugins ./pkg/model-serving-controller/controller ./pkg/model-booster-controller/convert
ok  all selected packages

go test $(go list ./... | grep -v /e2e)
ok  all selected packages

make lint
passed

make generate
tracked diff SHA-256 before: f7c9273f397a2c42382bc6c16766eacb6868734f1f333752a1c96c706f38653a
tracked diff SHA-256 after:  f7c9273f397a2c42382bc6c16766eacb6868734f1f333752a1c96c706f38653a

make gen-check
passed on the clean final implementation commit
```

Kind verification used image `kthena-controller-manager:dev-011-hookrequest`
with image ID
`sha256:b58daab34519f9635227c08598c4ccc90e29042ac03e92fcd47ce063458319e9`.
Observed results:

- without the plugin, only `user-managed-headless` existed;
- enabling the plugin created exactly 4 Headless Services;
- deleting `headless-plugin-0-serving-0-0` replaced UID
  `df97bf65-74d0-4b87-9cf1-83d170684173` with
  `342e0636-0898-42c7-95ca-e6a86201d9b0`, verifying `OnRoleSync` could use
  the request client/lister;
- after plugin removal, scaling Role replicas from 2 to 1 deleted both
  `serving-1` Services through `OnRoleDelete` while preserving both active
  `serving-0` Services and `user-managed-headless`;
- controller logs showed both deleted Roles returning their ServingGroups to
  `Running` with no plugin runtime resource errors.

The verification namespace and Helm release were removed afterward.

## Commits

```text
Kthena implementation:
5c522864b1c1db10a248460539b570c04909afd9
feat: manage headless services through plugin hooks

Issues task record:
this signed-off task-record commit
```

## Completion Criteria

- This revised proposal is explicitly approved before code changes.
- The superseded boolean implementation is fully replaced by the plugin.
- Services are absent from ServingGroup/Role existence checks and deletion
  waits.
- Generated artifacts are current and all non-E2E regression gates pass.
- Real Kind verification covers opt-in, recreation, cleanup, deletion
  decoupling, ownership isolation, and no Pod restart.
- Final signed-off implementation and task-record commits are documented.
