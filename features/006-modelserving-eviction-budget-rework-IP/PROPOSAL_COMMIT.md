# Proposal: Rework ModelServing Eviction Budget Semantics

## Context
This is a follow-up design review for
`issues/features/005-modelserving-pdb-DONE` and commit
`187ea0629eea02435cbe847c624b8bdf2bae3d0e`.

The original implementation added a `pods/eviction` validating webhook with:

- `rolloutStrategy.evictionStrategy.protectionLevel`
- `rolloutStrategy.evictionStrategy.minAvailable`
- ServingGroup and Role decision paths
- an in-memory `disruptionTracker` guarded by a mutex, which this rework
  replaces with a ConfigMap-backed tracker

The existing design is only opt-in at the ModelServing level: if a ModelServing
does not define `rolloutStrategy.evictionStrategy`, the webhook allows its Pod
evictions. However, once the `ValidatingWebhookConfiguration` is installed, the
API server still calls the webhook for every matching `pods/eviction` request.
There is no explicit cluster-level switch to remove this admission-path overhead.

## Findings

### 1. Role-level `minAvailable` is under-specified
Current API:

```go
type EvictionStrategySpec struct {
    ProtectionLevel ProtectionLevelType `json:"protectionLevel"`
    MinAvailable *intstr.IntOrString `json:"minAvailable"`
}
```

This gives all roles the same threshold. That does not match disaggregated
serving topologies where roles have different operational meaning and scale, for
example `prefill: 1`, `decode: 4`, and `controller: 1`.

The existing `GangPolicy.MinRoleReplicas` API already models this kind of
per-role requirement with a map keyed by role name. Eviction protection should
follow the same shape.

### 2. Role protection currently counts Pods, not role instances
The current Role path counts ready Pods with the target role label. That is not
the same as counting ready role replicas.

For a role with one entry Pod and multiple worker Pods, evicting any Pod makes the
logical role instance unavailable. Therefore the budget unit should be the
`modelserving.volcano.sh/role-id` unit, not an individual Pod.

Expected behavior:

- A role instance is ready only if all Pods belonging to its `role-id` are ready.
- Once one Pod in a role instance is being evicted, the whole role instance is
  considered unavailable for budgeting.
- Additional Pods from the same already-disrupted role instance should be allowed
  so the node drain can finish clearing that instance.

### 3. Concurrency model must support multi-replica webhook deployment
The controller-manager should remain highly available when eviction webhook is
enabled. Kubernetes Service routing does not understand controller leader
election, and using Pod readiness to expose only the leader would make
non-leader Pods NotReady and degrade Deployment/Helm health semantics.

Therefore the eviction budget tracker must be shared across webhook replicas.
This design uses a per-ModelServing ConfigMap as the shared tracker and relies on
Kubernetes `resourceVersion` conflicts to serialize budget consumption across
replicas.

### 4. Missing global enable/disable switch
The current implementation installs a `pods/eviction` admission webhook through
Helm. Even when no ModelServing enables `evictionStrategy`, eviction requests
still pay the cost of webhook admission round trips and webhook availability
becomes part of drain behavior.

Operators need a cluster-level switch that disables the feature by not installing
the eviction webhook configuration at all. The per-ModelServing
`evictionStrategy` field is still useful, but it is not sufficient as a global
performance and operational safety control.

## Enablement Model

Use two layers of enablement:

1. Cluster-level switch:
   - Helm value controls whether the `ValidatingWebhookConfiguration` for
     `pods/eviction` is rendered.
   - Controller-manager flag controls whether `/validate-eviction` is registered.
   - Default is disabled because 005 is not public and the feature adds admission
     latency to eviction requests.

2. ModelServing-level opt-in:
   - A ModelServing is protected only when
     `spec.rolloutStrategy.evictionStrategy` is set.
   - If the cluster-level switch is off, `evictionStrategy` is inert and should
     not affect Kubernetes eviction behavior.

Proposed Helm values:

```yaml
workload:
  controllerManager:
    evictionWebhook:
      enabled: false
      failurePolicy: Fail
      timeoutSeconds: 5
      trackerTTLSeconds: 60
```

Proposed controller flag:

```bash
--enable-eviction-webhook=false
--eviction-tracker-ttl=60s
```

Recommended behavior:

- When `evictionWebhook.enabled=false`, do not render the
  `ValidatingWebhookConfiguration` for `pods/eviction`.
- When `--enable-eviction-webhook=false`, do not register the HTTP handler.
- `--eviction-tracker-ttl` initializes how long an allowed logical eviction unit
  is kept in the ConfigMap tracker before informer state is expected to catch up.
- If the webhook configuration exists but the handler is disabled because of a
  configuration mismatch, return allow rather than fail closed. The install path
  should prevent this mismatch, but the runtime behavior should avoid accidental
  cluster-wide drain blockage.
- The feature should be documented as opt-in because it adds admission latency to
  every intercepted eviction request.
- When the Helm value enables the eviction webhook, the chart preserves
  `controllerManager.replicas`. Multi-replica correctness is provided by the
  shared ConfigMap tracker.

## Revised API Proposal

Keep the existing fields and add role-specific thresholds:

```go
type EvictionStrategySpec struct {
    // ProtectionLevel defines the protection level: ServingGroup or Role.
    // +kubebuilder:default=ServingGroup
    // +kubebuilder:validation:Enum={ServingGroup,Role}
    ProtectionLevel ProtectionLevelType `json:"protectionLevel"`

    // MinAvailable is used for ServingGroup protection.
    // It is ignored when protectionLevel is Role.
    MinAvailable *intstr.IntOrString `json:"minAvailable,omitempty"`

    // RoleMinAvailable defines role-specific minimum available role instances.
    // It is used only when protectionLevel is Role.
    // Map key is spec.template.roles[*].name.
    // Values can be absolute numbers or percentages.
    // +optional
    RoleMinAvailable map[string]intstr.IntOrString `json:"roleMinAvailable,omitempty"`
}
```

Example:

```yaml
rolloutStrategy:
  evictionStrategy:
    protectionLevel: Role
    minAvailable: 1
    roleMinAvailable:
      prefill: 1
      decode: 4
      controller: 1
```

Semantics:

- `ServingGroup` mode uses `minAvailable` exactly as before.
- `Role` mode checks `roleMinAvailable[targetRole]` first.
- If a target role is absent from `roleMinAvailable`, use Role-mode threshold
  `0`, meaning the role is not protected by eviction budget.
- Percent values in Role mode use expected role instance count as the denominator:
  `spec.replicas * spec.template.roles[role].replicas`.
- `roleMinAvailable` keys must match `spec.template.roles[*].name`. Unknown keys
  are rejected by the ModelServing validating webhook.
- `minAvailable` is not validated or used in Role mode.

## Revised Decision Model

### ServingGroup mode
Budget unit:

```text
ModelServing namespace/name + group-name
```

Ready unit:

- every Pod in the ServingGroup is ready;
- no active disruption tracker entry exists for the group.

Decision:

1. If target group is already unavailable, allow.
2. Otherwise compute ready groups after consuming one group.
3. Allow only if current ready group count is greater than `minAvailable`.
4. On allow, record the target group in the ConfigMap logical-unit tracker.

### Role mode
Budget unit:

```text
ModelServing namespace/name + role + role-id
```

Ready unit:

- every Pod in the role instance is ready;
- no active disruption tracker entry exists for that role instance.

Decision:

1. Resolve target role and target `role-id`.
2. If target role instance is already unavailable, allow.
3. Resolve threshold from `roleMinAvailable[targetRole]`. If the target role is
   absent, use Role-mode threshold `0`; do not read global `minAvailable`.
4. Count ready role instances for the target role.
5. Allow only if current ready role-instance count is greater than the threshold.
6. On allow, record the target role instance in the ConfigMap logical-unit
   tracker.

## Disruption Tracker

Use a ConfigMap-backed tracker as the correctness boundary for multi-replica
webhook deployment.

Reasons:

- The tracker only needs to bridge informer lag between "webhook allowed the
  eviction" and "the Pod deletion or readiness change is visible in cache".
- Multiple controller-manager replicas can receive `pods/eviction` admission
  requests through the normal webhook Service.
- A per-ModelServing ConfigMap avoids a single global hotspot and keeps conflicts
  scoped to one workload's drain budget.
- Direct API reads/writes avoid informer cache lag for the tracker itself.
- `resourceVersion` conflict retry forces concurrent writers to recompute the
  budget from the latest tracker state before allowing another logical unit.

Tracker shape:

```go
type disruptionTracker map[string]time.Time

type disruptionUnit struct {
    Namespace string
    ModelServing string
    Level string // ServingGroup or Role
    GroupName string
    Role string
    RoleID string
}
```

ConfigMap shape:

```text
namespace: <ModelServing namespace>
name: kthena-eviction-tracker-<ModelServing name>
data.entries: JSON map[logicalUnitKey]expiryTimestamp
```

Decision flow:

1. List current Pods from the informer cache.
2. Read or create the ModelServing tracker ConfigMap directly from the API
   server.
3. Decode entries and remove expired tracker entries.
4. Apply active tracker entries to mark affected logical units unavailable.
5. If eviction is denied, return HTTP 429.
6. If eviction is allowed and the target unit was previously ready, update
   `data.entries` with the target logical unit and TTL.
7. Update the ConfigMap using the observed `resourceVersion`.
8. If the update conflicts, retry from step 2 and recompute the budget.

Tracker TTL:

- Default is 60 seconds.
- It is configured at controller-manager startup, exposed through Helm as
  `workload.controllerManager.evictionWebhook.trackerTTLSeconds`.
- The TTL bridges informer lag only; it is not Pod termination grace period or
  service recovery time.
- The TTL expiry prevents a canceled or failed eviction from holding budget
  forever.

The tracker must be keyed by logical unit, not by Pod:

- ServingGroup mode key: `namespace/modelServing/groupName`
- Role mode key: `namespace/modelServing/role/roleID`

Failover behavior:

- If a controller-manager Pod dies after allowing an eviction, the tracker entry
  remains in the ConfigMap until TTL expiry.
- Other replicas will continue to observe the same shared tracker state.
- If the ConfigMap cannot be read or updated, the eviction is denied to avoid
  breaking the configured budget.

## Multi-node Drain Scenario

Scenario:

- `replicas: 5`
- `protectionLevel: ServingGroup`
- `minAvailable: 4`
- Node-A has a Pod from `group-0`
- Node-B has a Pod from `group-1`
- both nodes are drained at nearly the same time

Expected behavior:

1. First accepted request records its group in the ConfigMap logical-unit
   tracker.
2. The second request may be handled by another webhook replica, but it reads the
   same ConfigMap tracker and sees one tracked group as unavailable, even before
   informer cache updates.
3. Ready groups are effectively 4.
4. Since `4 > 4` is false, the second group eviction is denied with HTTP 429.
5. Retry succeeds only after the first group is actually recovered and ready.

## Implementation Plan

1. API and generated code:
   - add `RoleMinAvailable map[string]intstr.IntOrString`;
   - regenerate CRDs, clients, deepcopy, and docs.

2. Feature switch:
   - add Helm values for `workload.controllerManager.evictionWebhook.enabled`;
   - add Helm value for `trackerTTLSeconds` with default `60`;
   - guard rendering of the `pods/eviction` webhook configuration;
   - add a controller-manager flag to register or skip `/validate-eviction`;
   - add a controller-manager flag to configure tracker TTL;
  - preserve user-configured controller-manager replicas when eviction webhook is
    enabled;
   - document that the cluster-level switch removes admission-path overhead.

3. Validation:
   - validate `roleMinAvailable` keys against `spec.template.roles[*].name` in
     the ModelServing validating webhook;
   - validate all `roleMinAvailable` values as int-or-percent;
   - keep no-protection behavior for roles absent from `roleMinAvailable`,
     without reading global `minAvailable`.

4. Handler logic:
   - introduce logical budget units for ServingGroup and Role;
   - count Role mode by `role-id`, not raw Pods;
   - keep allowing Pods from already-unavailable units.

5. ConfigMap logical-unit tracker:
   - replace the Pod-keyed tracker with a logical-unit-keyed ConfigMap tracker;
   - use `resourceVersion` conflict retry for multi-replica consistency;
   - initialize tracker TTL from the controller-manager flag;
   - document API write behavior, failover behavior, and TTL limits.

6. Tests:
   - webhook disabled does not render `ValidatingWebhookConfiguration`;
   - handler disabled path allows requests if reached by configuration mismatch;
  - chart preserves controller-manager replicas when eviction webhook is enabled;
   - tracker TTL flag/default behavior;
   - invalid `roleMinAvailable` unknown role key rejected;
   - invalid `roleMinAvailable` int-or-percent value rejected;
   - role-specific thresholds;
   - Role thresholds resolved from `roleMinAvailable[targetRole]`;
   - role instance with entry plus worker Pods;
   - same-unit eviction allowed after first Pod consumes budget;
  - concurrent requests across two handler instances sharing one ConfigMap;
  - disabled handler behavior;
   - tracker TTL expiry.

7. Verification:
   - `go test ./pkg/model-serving-controller/webhook/...`;
   - full `go test ./...` before marking done;
   - Kind verification with concurrent `kubectl drain` on two nodes when a local
     cluster is available.

## Decisions

- `roleMinAvailable` keys must be validated against
  `spec.template.roles[*].name` in the ModelServing validating webhook.
- Tracker TTL is a controller-manager startup parameter with a default of 60
  seconds.
- The cluster-level eviction webhook switch defaults to disabled because 005 is
  not public and the webhook adds admission-path overhead.
- Controller-manager replicas are not forced to 1 when eviction webhook is
  enabled. Multi-replica consistency is handled by the ConfigMap tracker.

## Verification Results

- Unit Tests:
  - `go test ./pkg/model-serving-controller/webhook/...` passed.
  - `go test $(go list ./... | grep -v /e2e | grep -v /client-go)` passed.
  - `go test ./...` was attempted. Non-e2e packages passed, but e2e packages
    failed because the configured Kubernetes API server
    `https://127.0.0.1:51102` was unreachable.
- Generation:
  - `make generate` was attempted and completed CRD/client/docs generation.
  - The command failed at `gen-copyright` because local `sponge`/`moreutils` is
    not installed.
- Helm:
  - `helm lint ./charts/kthena` passed.
  - `helm template` verified the default chart does not render the
    `pods/eviction` webhook rule.
  - `helm template --set workload.controllerManager.evictionWebhook.enabled=true`
    verified the eviction webhook rule is rendered.
  - `helm template --set workload.controllerManager.replicas=3 --set workload.controllerManager.evictionWebhook.enabled=true`
    verified controller-manager renders `replicas: 3`.
- Kind:
  - Local Kind cluster `kind` was available with arm64 nodes:
    `kind-control-plane`, `kind-worker`, and `kind-worker2`.
  - Built Linux/arm64 controller-manager binary:
    `GOOS=linux GOARCH=arm64 go build -o ../local-output/kthena-controller-manager ./cmd/kthena-controller-manager/main.go`.
  - Built local image:
    `docker build -t kthena-controller-manager:dev-006 -f Dockerfile.local --build-arg BINARY_DIR=local-output --build-arg BINARY_NAME=kthena-controller-manager .`.
  - Loaded image into Kind:
    `kind load docker-image kthena-controller-manager:dev-006 --name kind`.
  - Upgraded Kthena with eviction webhook enabled and local image:
    `helm upgrade --install kthena ./charts/kthena --namespace kthena-system ... --set workload.controllerManager.evictionWebhook.enabled=true`.
  - Verified controller-manager rendered and ran with eviction webhook args:
    `--enable-eviction-webhook=true`, `--eviction-tracker-ttl=60s`.
  - Verified `eviction.modelserving.volcano.sh` was present in
    `kthena-controller-manager-validating-webhook` while enabled.
  - Updated the ModelServing CRD with `kubectl replace -f ...modelservings.yaml`.
    `kubectl apply` could not be used because the existing CRD lacked
    `last-applied-configuration` and the generated annotation would exceed the
    Kubernetes annotation size limit.
  - Verified invalid `roleMinAvailable` key is rejected by the ModelServing
    validating webhook:
    `role unknown does not exist in template.roles`.
  - Created `evict-sg` ServingGroup-mode ModelServing with `minAvailable: 2`.
    A real raw API `pods/eviction` request for `evict-sg-0-worker-0-0` returned
    `201 Success`; a second immediate eviction for a different group
    `evict-sg-1-worker-0-0` was denied:
    `Current ready groups (2) <= minAvailable (2)`.
  - Created `evict-role` Role-mode ModelServing with
    `roleMinAvailable.decode: 1`. Real raw API eviction requests for
    `decode-0` entry and worker Pods both returned `201 Success`; a subsequent
    eviction for `decode-1` was denied:
    `Role decode ready instances (1) <= minAvailable (1)`.
  - Disabled the eviction webhook with Helm and verified
    `eviction.modelserving.volcano.sh` was removed from the validating webhook
    configuration.
  - Cleaned up the verification namespace with
    `kubectl delete namespace eviction-006 --wait=false`.
- Manual Verification:
  - Existing 005 design and commit reviewed.
  - Verification manifests and eviction request payloads are stored in this
    issue directory.

### 2026-06-08 Role `minAvailable` bugfix verification

- Fixed two Role-mode eviction webhook bugs:
  - global `evictionStrategy.minAvailable` is no longer validated or used when
    `protectionLevel=Role`;
  - Role-mode thresholds are resolved from
    `roleMinAvailable[targetRole]`, with internal default `0` only when the
    target role is absent from the map.
- Updated API/CRD/docs semantics:
  - removed the CRD default for `minAvailable`;
  - documented `minAvailable` as ServingGroup-only.
- Unit/regression verification:
  - `go test ./pkg/model-serving-controller/webhook` passed.
  - `env GOCACHE=/private/tmp/kthena-go-cache go test $(go list ./... | grep -v /e2e | grep -v /client-go)` passed.
  - `make gen-crd` passed with `GOCACHE=/private/tmp/kthena-go-cache`.
  - Initial `make gen-crd` without `GOCACHE` failed because the local user Go
    cache contained missing compiled cache entries.
  - The non-e2e Go test command printed a module stat-cache permission warning
    for `/Users/vanderchen/go/pkg/mod/cache/...`, but exited successfully.
- Kind verification:
  - Current context was `kind-kind`; node architecture was `arm64`.
  - Built Linux/arm64 controller-manager binary:
    `env GOOS=linux GOARCH=arm64 GOCACHE=/private/tmp/kthena-go-cache go build -o ../local-output/kthena-controller-manager ./cmd/kthena-controller-manager/main.go`.
  - Built image:
    `docker build -t kthena-controller-manager:dev-006-eviction-role-minavailable -f Dockerfile.local --build-arg BINARY_DIR=local-output --build-arg BINARY_NAME=kthena-controller-manager .`.
  - Loaded image:
    `kind load docker-image kthena-controller-manager:dev-006-eviction-role-minavailable --name kind`.
  - Upgraded release:
    `helm upgrade kthena ./charts/kthena --namespace kthena-system --reuse-values --set workload.controllerManager.image.repository=kthena-controller-manager --set workload.controllerManager.image.tag=dev-006-eviction-role-minavailable --set workload.controllerManager.image.pullPolicy=IfNotPresent --set workload.controllerManager.evictionWebhook.enabled=true`.
  - Updated ModelServing CRD with server-side apply because normal
    `kubectl apply` exceeded annotation size:
    `kubectl apply --server-side --force-conflicts -f charts/kthena/charts/workload/crds/workload.serving.volcano.sh_modelservings.yaml`.
  - Verified rollout:
    `kubectl rollout status deploy/kthena-controller-manager -n kthena-system --timeout=120s`.
  - Confirmed CRD no longer defaults `minAvailable`:
    `kubectl get crd modelservings.workload.serving.volcano.sh -o jsonpath='{...minAvailable.default}'` returned empty output.
  - Role configuration without global `minAvailable` is covered by unit tests.
  - Detailed multi-role Kind verification is recorded in the follow-up section
    below using `roleMinAvailable.decode: 2` and `roleMinAvailable.prefill: 1`.
  - No e2e tests were run.

### 2026-06-08 Role missing-key and per-role threshold follow-up

- Corrected Role-mode missing-key semantics:
  - if `roleMinAvailable[targetRole]` is absent, the threshold is `0`;
  - threshold `0` means this role is not protected by the eviction budget;
  - global `minAvailable` is still ignored in Role mode.
- Added unit coverage:
  - `decode: 2` is denied when current ready decode instances are `2`;
  - `prefill: 1` is allowed when current ready prefill instances are `2`;
  - role absent from `roleMinAvailable` is allowed with default threshold `0`.
- Added Kind verification artifacts:
  - `kind-role-per-role-minavailable.yaml`;
  - `evict-role-per-role-decode-0.json`;
  - `evict-role-per-role-prefill-0.json`;
- Unit/regression verification:
  - `env GOCACHE=/private/tmp/kthena-go-cache go test ./pkg/model-serving-controller/webhook` passed.
  - `env GOCACHE=/private/tmp/kthena-go-cache go test $(go list ./... | grep -v /e2e | grep -v /client-go)` passed.
  - The non-e2e Go test command again printed the user module stat-cache
    permission warning, but exited successfully.
- Kind verification:
  - Built and loaded image
    `kthena-controller-manager:dev-006-eviction-role-minavailable-v2`.
  - Upgraded `kthena` release with eviction webhook enabled and the v2 image.
  - Applied `kind-role-per-role-minavailable.yaml`, which sets
    `roleMinAvailable.decode: 2` and `roleMinAvailable.prefill: 1`.
  - Waited for both decode Pods and both prefill Pods to become Ready.
  - Raw eviction for `decode-0` was denied with:
    `role decode ready instances (2) <= minAvailable (2)`.
  - Raw eviction for `prefill-0` returned `201 Success`; controller log showed
    `targetRole="prefill"` and `minAvailable=1`.
  - Cleaned up the live verification namespace:
    `kubectl delete namespace eviction-006-role-per-role-minavailable --wait=false`.
  - No e2e tests were run.

## Associated Commits

- Original commit under review:
  `187ea0629eea02435cbe847c624b8bdf2bae3d0e`
- Implementation branch: `feat/006-modelserving-eviction-budget-rework`
- Implementation commits: pending commit.
