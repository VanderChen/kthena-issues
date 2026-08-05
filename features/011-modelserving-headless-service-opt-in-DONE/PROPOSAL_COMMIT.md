# Proposal: Opt-in ModelServing Headless Services

## Status

Implemented and verified. The proposal was approved before implementation, all
required non-E2E regression gates passed, and the behavior was exercised in the
local Kind cluster.

Target implementation branch:

```text
feat/011-modelserving-headless-service-opt-in
```

Implementation commit:

```text
ab2cd1548238bf424ff379676d279fc97a3d9638
```

## Baseline and Current Behavior

The proposal was inspected against local Kthena `main` at commit
`50c81455`.

Relevant implementation paths:

```text
pkg/apis/workload/v1alpha1/model_serving_types.go
pkg/model-serving-controller/controller/model_serving_controller.go
pkg/model-serving-controller/controller/model_serving_controller_test.go
pkg/model-serving-controller/utils/utils.go
charts/kthena/charts/workload/crds/workload.serving.volcano.sh_modelservings.yaml
test/e2e/controller-manager/model_serving_test.go
```

Current reconciliation has these properties:

1. `syncModelServing` always invokes `manageHeadlessService`.
2. `manageHeadlessService` walks every active ServingGroup, Role definition, and
   active Role replica.
3. When a Role has `workerTemplate`, the controller creates a Headless Service
   named after the entry Pod for that Role replica.
4. The Service is owned by the ModelServing, uses `clusterIP: None`, sets
   `publishNotReadyAddresses: true`, and selects the entry Pod by the generated
   group, role, role-ID, and entry labels.
5. Workers receive an `ENTRY_ADDRESS` based on the entry-Pod/Service DNS name.
6. Service deletion enqueues the owning ModelServing, so the Service is
   recreated on the next reconcile.

This means even workloads that never use the generated DNS contract accumulate
Services proportional to their ServingGroup and Role replica counts.

## API Design

Add one top-level field to `ModelServingSpec`:

```go
type ModelServingSpec struct {
    // Existing fields omitted.

    // EnableHeadlessService controls whether the controller creates one
    // Headless Service for each active Role replica with a WorkerTemplate.
    // It is disabled by default and must be explicitly enabled by workloads
    // that require the generated entry/worker DNS behavior.
    // +optional
    EnableHeadlessService bool `json:"enableHeadlessService,omitempty"`
}
```

A non-pointer boolean is sufficient because omitted and explicit `false` have
the same desired state. No `+kubebuilder:default=true` or mutating-webhook
default will be added. The generated OpenAPI schema will expose an optional
boolean, and only a literal `true` enables creation.

The field is top-level rather than nested under `template` because it controls
controller-owned auxiliary resources for the entire ModelServing. It is not a
Pod-template input and must not participate in the Role revision hash.

## Reconciliation Design

Turn Headless Service handling into a two-state desired-resource reconciliation:

```text
enableHeadlessService == true
  -> execute the existing create/recovery path

enableHeadlessService == false or omitted
  -> skip ServingGroup/Role traversal
  -> delete existing Headless Services owned by this ModelServing UID
  -> never recreate them
```

### Enabled path

Preserve the existing behavior:

- only Roles with `workerTemplate` receive Services;
- keep current Service names, labels, owner references, entry-Pod selector, and
  `publishNotReadyAddresses` setting;
- retain idempotent create and stale-owner handling;
- retain automatic recreation after an enabled Service is deleted.

### Disabled cleanup path

When disabled, list candidate Services from the already-synchronized informer
cache using the ModelServing name label. Before deletion, require all of the
following:

- the Service is in the ModelServing namespace;
- `spec.clusterIP` is `None`;
- its controller owner reference matches the current ModelServing UID.

Delete matching Services through the Kubernetes client. Ignore `NotFound` and
return other delete failures so the workqueue retries reconciliation. This
avoids an extra API-server list call and prevents similarly labelled
user-managed or stale-instance Services from being deleted.

The disabled path must return before consulting ServingGroup or Role state, so
the default case avoids all Headless-Service create/recovery work.

### State transitions

| Transition/event | Result |
| --- | --- |
| omitted/`false` on create | no Headless Services |
| omitted/`false` to `true` | expected Services created on the next reconcile |
| `true` to `false` | owned Headless Services deleted on the next reconcile |
| enabled Service manually deleted | Service recreated |
| disabled Service manually deleted | no recreation |
| ServingGroup/Role scale down while enabled | existing scoped cleanup remains in effect |

The ModelServing update handler already enqueues spec changes. The current
revision calculation is Role-template based, so changing this new top-level
field will reconcile Services without rolling Pods.

## Upgrade and Migration Semantics

Omitted means disabled for both new and existing ModelServing objects. As a
result, after the new controller reconciles an existing object without the new
field, its old controller-owned Headless Services are deleted.

This cleanup is intentional: merely stopping new creation would leave old
clusters with an indefinitely different desired state and would not reclaim
the existing API objects. The release note and user documentation must call out
that workloads using the DNS contract need to opt in before upgrade:

```yaml
spec:
  enableHeadlessService: true
```

If immediate cleanup during upgrade is considered too disruptive during review,
the fallback is to skip cleanup for omitted/`false`. That alternative is not
recommended because `false` would not converge to a resource-free state and the
controller could not distinguish an upgrade omission from an explicit disable.

## Implementation Scope

### API and generated artifacts

- Add `EnableHeadlessService` to
  `pkg/apis/workload/v1alpha1/model_serving_types.go`.
- Run `make generate` to update generated CRDs, clients/apply configurations,
  DeepCopy output, and CRD/API reference documentation.
- Run `make gen-check` from a clean generated state.

Expected generated/user-facing outputs include the ModelServing workload CRD,
client-go apply configuration, and current CRD reference documentation. Files
matching `zz_generated_*.go` will not be edited manually.

### Controller

- Gate the Headless Service create/recovery traversal on
  `ms.Spec.EnableHeadlessService`.
- Add a cache-backed cleanup helper for the disabled desired state.
- Filter cleanup by namespace, ModelServing label, Headless Service identity,
  and current owner UID.
- Preserve current enabled behavior and Service format.
- Propagate cleanup errors so normal workqueue retry semantics apply.

### Compatibility integrations

- ModelBooster-generated ModelServings explicitly enable Headless Services
  when any generated Role has worker Pods, preserving the `ENTRY_ADDRESS`
  contract used by multi-node vLLM workers.
- LWS-generated ModelServings explicitly enable Headless Services when the LWS
  group has worker Pods, preserving stable leader DNS.
- Current data-parallel and multi-node ModelServing examples that consume
  `ENTRY_ADDRESS` now opt in explicitly.

### Documentation

- Document the new optional field and its default-disabled semantics.
- Add an opt-in YAML fragment for workloads requiring generated entry/worker
  DNS.
- Record the upgrade incompatibility and migration step.

No new external dependencies are required.

## Test Plan

### Unit tests

Extend the Headless Service controller tests to cover:

1. omitted field plus `workerTemplate` creates zero Services;
2. explicit `false` creates zero Services;
3. explicit `true` creates the same Services as today;
4. explicit `true` remains idempotent when the Service already exists;
5. disabled reconciliation deletes existing Services owned by the same
   ModelServing UID;
6. disabled reconciliation preserves a user-managed Service and a Service owned
   by another ModelServing UID, even if labels overlap;
7. a delete failure is returned for retry;
8. Roles without `workerTemplate`, deleting Roles, and deleting ServingGroups
   retain their existing enabled-path behavior.

The test fixture must seed both the fake API client and Service informer indexer
when validating cache-backed cleanup.

### Existing E2E coverage updates

Update Headless-Service-specific E2E fixtures to explicitly set
`enableHeadlessService: true`:

- ServingGroup scale-down Service cleanup;
- manually deleted Service recovery.

The recovery test should require the opted-in Service to exist rather than skip
when none is found, so a regression cannot pass silently.

Per workspace policy, the repository E2E suite will not be run by default.

### Regression gates

From the implementation branch in `kthena/`:

```bash
make generate
make gen-check
go test $(go list ./... | grep -v /e2e)
```

Run focused controller/API tests during development, and run formatting/linting
appropriate to the touched Go files before final verification.

## Mandatory Kind Verification

After unit/regression tests, build the controller for the Kind node architecture,
build and load image `kthena-controller-manager:dev-011`, and deploy it with the
workspace's documented Helm flow.

Use a ModelServing with at least one Role containing a `workerTemplate` and
verify this sequence:

1. Apply it without `enableHeadlessService`; wait for reconciliation and prove
   that zero ModelServing-owned Headless Services exist.
2. Patch `spec.enableHeadlessService=true`; prove the exact expected Service
   count and inspect `clusterIP`, owner UID, labels, selector, and
   `publishNotReadyAddresses`.
3. Capture Pod UIDs before and after enabling to prove no Pod rollout occurred.
4. Delete one generated Service; prove it is recreated with a new UID.
5. Patch `spec.enableHeadlessService=false`; prove all owned Headless Services
   are deleted and remain absent across subsequent reconciliations.
6. Confirm unrelated Services are preserved and ModelServing Pods keep the same
   UIDs.

Record the exact commands, workload YAML, observed counts/UIDs, controller logs,
and any artifacts in this file before marking the feature `DONE`.

## Completion Criteria

- Proposal explicitly approved before implementation.
- API and controller behavior implemented on the feature branch.
- Generated artifacts are current and `make gen-check` is clean.
- Focused and full non-E2E Go regression gates pass.
- Real Kind verification demonstrates default-off, opt-in creation/recovery,
  opt-out cleanup, resource isolation, and no Pod restart.
- Final results and signed-off commit hashes are recorded here.
- Task folder renamed from `IP` to `DONE` only after all checks pass.

## Verification Results

- Focused Go tests: passed.

  ```bash
  go test ./pkg/model-serving-controller/controller ./pkg/model-booster-controller/convert
  ```

- Full non-E2E regression gate: passed.

  ```bash
  go test $(go list ./... | grep -v /e2e)
  ```

- Go lint: passed.

  ```bash
  make lint
  ```

- Generated artifacts: `make generate` completed successfully; after the
  implementation commit, `make gen-check` completed with a clean diff.
- Repository E2E suite: not executed, following the workspace policy. Existing
  Headless-Service-specific E2E cases were updated to opt in explicitly, and
  the recovery test now fails instead of skipping when its expected Service is
  absent.

### Kind environment

```text
context: kind-kind
cluster: kind
nodes: 4 Ready nodes
architecture: arm64
Kubernetes: v1.36.1
Volcano Helm release: 1.14.1
controller image: kthena-controller-manager:dev-011
image SHA: 80531cc678611250b411e77b1659c7ce07558ada55db439d042da4422cd6186a
controller deployment: 1/1 Available
```

The controller binary was built from the Kthena module root because the
workspace root has no `go.work` file:

```bash
GOOS=linux GOARCH=arm64 go build \
  -o ../local-output/kthena-controller-manager-011 \
  ./cmd/kthena-controller-manager/main.go

docker build -t kthena-controller-manager:dev-011 \
  -f Dockerfile.local \
  --build-arg BINARY_DIR=local-output \
  --build-arg BINARY_NAME=kthena-controller-manager-011 .

kind load docker-image kthena-controller-manager:dev-011 --name kind

helm upgrade --install kthena ./charts/kthena \
  --namespace kthena-system \
  --create-namespace \
  --set networking.enabled=false \
  --set workload.controllerManager.image.repository=kthena-controller-manager \
  --set workload.controllerManager.image.tag=dev-011 \
  --set workload.controllerManager.image.pullPolicy=IfNotPresent \
  --wait --timeout 3m
```

The installed CRD exposed
`spec.versions[*].schema.openAPIV3Schema.properties.spec.properties.enableHeadlessService.type`
as `boolean`.

### Kind behavior verification

The preserved verification manifest is
`kind-headless-service-opt-in.yaml`. It creates:

- two ServingGroups;
- two `serving` Role replicas per ServingGroup;
- one entry and one worker Pod per Role replica;
- one similarly labelled, user-managed Headless Service without a
  ModelServing owner reference.

Observed sequence:

1. With `enableHeadlessService` omitted, the ModelServing reached
   `Available=True`, `availableReplicas=2`, and all eight Pods became Ready.
   Zero ModelServing-owned Headless Services existed; only
   `user-managed-headless` existed.
2. After patching `enableHeadlessService=true`, exactly four owned Headless
   Services appeared. Every generated Service had `clusterIP: None`,
   `publishNotReadyAddresses: true`, owner UID
   `43894eb8-3ecc-4395-a675-1701d3e9bb78`, and the expected group/role/role-ID/
   entry selector.
3. All Pod UIDs were unchanged after enabling:

   ```text
   headless-opt-in-0-serving-0-0  2edd4004-ad75-46ca-8e8b-e7ccde68207b
   headless-opt-in-0-serving-0-1  7c9550f8-9ffa-4838-b2b2-309fcffbc112
   headless-opt-in-0-serving-1-0  adc03ea3-9041-44f3-bd0f-e9ff5b597ba6
   headless-opt-in-0-serving-1-1  93617a62-4003-4dd9-817d-5ab86eadfd54
   headless-opt-in-1-serving-0-0  d4b0133f-185d-4dbc-9069-67e14a73989d
   headless-opt-in-1-serving-0-1  54801686-134e-4f73-a8c5-1a53fc290039
   headless-opt-in-1-serving-1-0  55aab7f9-f601-4dfd-a47a-d756162138c8
   headless-opt-in-1-serving-1-1  d767ee90-210b-4247-8c21-50c50aec12e7
   ```

4. Deleting `headless-opt-in-0-serving-0-0` recreated it immediately; its
   Service UID changed from `19c62af3-0ae1-469e-9708-8f38e7eae5e9` to
   `4e723a85-e93b-457d-bba1-c664dac27f7c`.
5. After patching `enableHeadlessService=false`, all four owned Services were
   deleted and remained absent. `user-managed-headless` was preserved.
6. All eight Pod UIDs remained identical after disabling, and the ModelServing
   remained `Available=True` with `availableReplicas=2` and
   `observedGeneration=3`.
7. Controller logs contained no errors related to the feature during creation,
   enablement, Service recovery, or disable cleanup.

## Associated Commits

- Commit ID: `ab2cd1548238bf424ff379676d279fc97a3d9638`.
- Branch: `feat/011-modelserving-headless-service-opt-in`.
- Commit sign-off: `Signed-off-by: Min Chen <vanderchen@outlook.com>`.
