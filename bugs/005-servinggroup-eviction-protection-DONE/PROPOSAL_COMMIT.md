# Proposal: Fix ServingGroup eviction availability for multi-role groups

## Branch

- Base branch: `feat/006-modelserving-eviction-budget-rework`
- Fix branch: `fix/005-servinggroup-eviction-protection`

`main` does not contain the eviction handler yet, so this bug must be fixed on
top of the in-progress eviction budget rework.

## Characterization

Current implementation:

- `checkServingGroupProtection` groups Pods by
  `modelserving.volcano.sh/group-name`.
- `isServingGroupReady` returns false if the group has an active disruption
  tracker entry.
- Otherwise it calls `arePodsReady(pods)`.
- `arePodsReady` returns true when all listed Pods are Ready.

There are two gaps to verify:

1. The listed Pod slice may be incomplete. A ServingGroup with two roles can
   still have one Ready Pod listed after another role Pod was deleted or has not
   appeared in the informer cache. That partial group is then treated as
   available.
2. The code allows evicting a target ServingGroup when that group is already not
   ready. This is intended to let a drain finish clearing a disrupted logical
   unit, but if the group was not made unavailable through an already accounted
   ServingGroup disruption unit, this can bypass `minAvailable`.

This specifically affects `protectionLevel: ServingGroup` because the budget is
defined over complete ServingGroups, not over individual Pods or roles.

## Reproduction Plan

Use `reproduce-multirole-servinggroup.yaml`:

- `spec.replicas: 3`
- two roles: `prefill` and `decode`
- `protectionLevel: ServingGroup`
- `minAvailable: 2`

After applying the manifest, inspect placement:

```bash
kubectl get pod -n eviction-005 \
  -l modelserving.volcano.sh/name=evict-sg-multirole \
  -o wide
```

The bug must be verified in two placements:

- all Pods scheduled onto the same node;
- role-level spread across nodes, for example one node has multiple `prefill`
  Pods from different ServingGroups while another node has the matching `decode`
  Pods.

Expected verification:

1. The first eviction against one complete ready ServingGroup can be allowed.
2. A second eviction that would make fewer than two complete ServingGroups
   available must be denied.
3. After one role Pod is gone from a ServingGroup, that group must not be counted
   Ready just because another role Pod in the same group remains Ready.
4. A ServingGroup that is already not ready for reasons unrelated to an accounted
   ServingGroup disruption must not be freely evictable when doing so would leave
   fewer than `minAvailable` complete ready ServingGroups.

## Proposed Fix

### Revised Scope

The user confirmed the current ConfigMap-backed eviction handler is the relevant
version. The older in-memory tracker behavior is only historical reproduction
context.

Add logs that make each eviction decision explainable from controller-manager
logs:

- unmanaged or unconfigured Pods are allowed with an explicit bypass reason;
- ServingGroup decisions log target group state, ready group count, observed
  groups, total replicas, `minAvailable`, per-group ready/tracker state, and the
  final allow/deny reason;
- Role decisions log the equivalent role instance state;
- ConfigMap tracker decisions log retry attempt, tracker resourceVersion,
  active tracker keys, chosen disruption unit, and tracker update result.

The added logs exposed the actual current-version bypass: with
`kthena-controller-manager` replicas set to 2, a webhook replica whose
ModelServing informer cache has not synced can receive eviction requests for
Pods that already carry the ModelServing label. The old handler treated
`msLister.Get(...)` NotFound as an allow decision. Those requests never reached
the ConfigMap tracker, so `minAvailable` could be bypassed.

Fix:

- when the Pod lister misses an eviction target, fall back to a live Pod GET
  before deciding;
- when the ModelServing lister misses a labeled Pod's owner, fall back to a live
  ModelServing GET before deciding;
- only allow on confirmed API-server NotFound;
- deny on live GET errors that prevent protection evaluation.

This keeps the normal informer path fast while avoiding fail-open behavior from
temporary cache lag.

### Original Algorithmic Proposal

Change ServingGroup availability from "all listed Pods are Ready" to "this
ServingGroup is either the already accounted disruption unit, or all expected
Pods for the ServingGroup are present and Ready".

Implementation details:

- Add a helper to compute the expected Pod count for one ServingGroup from
  `ms.Spec.Template.Roles`:
  `sum(role.replicas * (1 + role.workerReplicas))`, using the existing replica
  defaulting helper.
- Update `isServingGroupReady` to return false when the listed Pod count is below
  the expected count.
- Keep the existing disruption tracker behavior only for the same accounted
  ServingGroup: additional Pods from that same disrupted group may be allowed so
  drain can finish clearing it.
- Do not treat every non-ready target ServingGroup as automatically evictable.
  If the target group is not already tracked as the active disrupted unit,
  evaluate the eviction against the current number of complete ready
  ServingGroups.
- Add a targeted unit test for three ServingGroups with two roles where one role
  Pod from a group is missing but the other role Pod remains Ready.
- Add a concurrency-style unit test that evicts one role Pod from one
  ServingGroup, then verifies an eviction from a second ServingGroup is denied
  while `minAvailable: 2`.
- Add a same-node drain-order unit test: all six Pods carry the same `NodeName`;
  after one ServingGroup is accounted as disrupted, eviction from another
  ServingGroup is denied even though all Pods are on the same node.

## Adjacent Risk

The Role-level helper currently has a similar shape: it checks only listed Pods
for a role instance. This proposal keeps the requested bug focused on
ServingGroup protection, but the implementation should evaluate whether the same
expected-pod completeness check should be shared with Role protection so a role
instance with missing worker Pods is not counted Ready.

## Verification Plan

Run from `kthena/` after implementation:

```bash
go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandler'
go test ./pkg/model-serving-controller/webhook
go test ./...
```

Optional Kind verification when the local cluster is available:

```bash
kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}'
kubectl apply -f ../issues/bugs/005-servinggroup-eviction-protection-IP/reproduce-multirole-servinggroup.yaml
kubectl get pod -n eviction-005 -l modelserving.volcano.sh/name=evict-sg-multirole -o wide
```

If the Pod placement does not exercise cross-node role spread, adjust node
selectors or drain the node that contains Pods from multiple ServingGroups before
collecting eviction results.

## Verification Results

### Logging-Only Implementation Verification

Changed `pkg/model-serving-controller/webhook/eviction_handler.go` to add
decision-state logs around the current ConfigMap tracker path.

Validation:

```text
GOCACHE=/private/tmp/kthena-go-cache go test ./pkg/model-serving-controller/webhook
ok  	github.com/volcano-sh/kthena/pkg/model-serving-controller/webhook	1.365s
```

### Current ConfigMap Version, Replica 2 Reproduction

Deployed `kthena-controller-manager:dev-005-logs` with:

```text
replicas=2
--enable-eviction-webhook=true
--eviction-tracker-ttl=60s
```

Created `evict-sg-logs` in `eviction-005-logs` with three ServingGroups and two
roles per group. All six Pods were Ready on `kind-worker`.

Drain result before the live GET fix:

```text
pod/evict-sg-logs-2-prefill-0-0 evicted
pod/evict-sg-logs-1-prefill-0-0 evicted
pod/evict-sg-logs-0-decode-0-0 evicted
pod/evict-sg-logs-0-prefill-0-0 evicted
pod/evict-sg-logs-1-decode-0-0 evicted
pod/evict-sg-logs-2-decode-0-0 evicted
node/kind-worker drained
```

Logs showed five eviction requests bypassed protection on one webhook replica:

```text
Allowing eviction ... because ModelServing eviction-005-logs/evict-sg-logs was not found
```

Only one request reached the ConfigMap tracker and recorded:

```text
ServingGroup/eviction-005-logs/evict-sg-logs/evict-sg-logs-1
```

### Fixed ConfigMap Version Verification

Built and deployed `kthena-controller-manager:dev-005-logs-fix`, still with two
controller-manager replicas and eviction webhook enabled.

Created `evict-sg-logs-fix` in `eviction-005-logs-fix`. All six Pods were Ready
and all were scheduled onto `kind-worker`.

Drain result after the live GET fix:

```text
pod/evict-sg-logs-fix-0-decode-0-0 evicted
pod/evict-sg-logs-fix-0-prefill-0-0 evicted
error when evicting pods/... denied the request:
Eviction denied: protected by ModelServing evict-sg-logs-fix.
Current ready groups (2) <= minAvailable (2).
error: unable to drain node "kind-worker" ... global timeout reached: 45s
```

Tracker ConfigMap after the run:

```text
entries:
  ServingGroup/eviction-005-logs-fix/evict-sg-logs-fix/evict-sg-logs-fix-0
```

Representative decision log:

```text
ServingGroup eviction state ... targetGroup="evict-sg-logs-fix-2"
readyGroups=2 observedGroups=3 totalReplicas=3 minAvailable=2
allowed=false
groupStates=[
  evict-sg-logs-fix-0(pods=2,ready=false,tracked=true)
  evict-sg-logs-fix-1(pods=2,ready=true,tracked=false)
  evict-sg-logs-fix-2(pods=2,ready=true,tracked=false)
]
Eviction tracker decision ... trackerEntries=1
trackerKeys=[ServingGroup/eviction-005-logs-fix/evict-sg-logs-fix/evict-sg-logs-fix-0]
```

Validation:

```text
GOCACHE=/private/tmp/kthena-go-cache go test ./pkg/model-serving-controller/webhook
ok  	github.com/volcano-sh/kthena/pkg/model-serving-controller/webhook	1.196s
```

### Final Status

Implementation is complete. The fix keeps the ConfigMap-backed tracker path and
adds live API GET fallback for Pod and ModelServing lister cache misses so
multi-replica webhook cache lag cannot bypass protection. Diagnostic logs now
show the eviction decision, current ServingGroup or Role state, tracker
resourceVersion, tracker keys, update conflicts, and final allow/deny reason.

Final regression:

```text
GOCACHE=/private/tmp/kthena-go-cache go test ./...
```

Sandbox run failed because local port binding and Kubernetes API access were
blocked. The non-sandbox run passed all non-e2e packages. The remaining failures
were limited to `test/e2e/...`, where the e2e framework attempted to install a
new Helm release into namespace `dev` but the existing local verification
release in `kthena-system` already owns cluster-scoped resources:

```text
ClusterRole "kthena-router" ... exists and cannot be imported into the current release
meta.helm.sh/release-namespace must equal "dev": current value is "kthena-system"
```

No implementation package failed after non-sandbox permissions were allowed.
Per user instruction, e2e verification is not required for this task.

### Initial Cluster State

The local Kind cluster initially had Kthena deployed with eviction protection
disabled globally:

```text
workload.controllerManager.evictionWebhook.enabled=false
controller args: --enable-eviction-webhook=false
ValidatingWebhookConfiguration: no pods/eviction rule
```

In that state, `rolloutStrategy.evictionStrategy` on a `ModelServing` is inert:
the API server does not call `/validate-eviction`, so controller logs only show
ordinary Pod deletion/recreate behavior. This configuration explains an apparent
"protection does not work" result if the Helm switch is off.

### Direct Eviction API, Current Local Source

Built and deployed current branch `0987a75b` as
`kthena-controller-manager:dev-005`, with:

```text
--enable-eviction-webhook=true
--eviction-tracker-ttl=60s
```

Created `evict-sg-dev005` in `eviction-005-dev005`:

```text
replicas: 3
roles: prefill, decode
protectionLevel: ServingGroup
minAvailable: 2
nodeSelector: kubernetes.io/hostname=kind-worker
```

Pod placement before eviction:

```text
evict-sg-dev005-0-decode-0-0    kind-worker
evict-sg-dev005-0-prefill-0-0   kind-worker
evict-sg-dev005-1-decode-0-0    kind-worker
evict-sg-dev005-1-prefill-0-0   kind-worker
evict-sg-dev005-2-decode-0-0    kind-worker
evict-sg-dev005-2-prefill-0-0   kind-worker
```

Results:

- Evicting `evict-sg-dev005-0-prefill-0-0` returned `201 Success`.
- The tracker ConfigMap was created with:

  ```text
  ServingGroup/eviction-005-dev005/evict-sg-dev005/evict-sg-dev005-0
  ```

- Evicting `evict-sg-dev005-0-decode-0-0` returned `201 Success`, as expected
  for the same already-accounted ServingGroup.
- Evicting `evict-sg-dev005-1-prefill-0-0` was denied:

  ```text
  admission webhook "eviction.modelserving.volcano.sh" denied the request:
  Eviction denied: protected by ModelServing evict-sg-dev005.
  Current ready groups (2) <= minAvailable (2).
  ```

Controller logs for this run show only `evict-sg-dev005-0` entering
`RoleDeleting` and then being recreated. `evict-sg-dev005-1` and
`evict-sg-dev005-2` did not enter `RoleDeleting`.

### Real `kubectl drain`, Same-Node Placement

Created `evict-sg-drain` in `eviction-005-drain`, also with all six Pods on
`kind-worker`.

Ran:

```bash
kubectl drain kind-worker \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --pod-selector=modelserving.volcano.sh/name=evict-sg-drain \
  --timeout=45s
kubectl uncordon kind-worker
```

Drain output:

```text
node/kind-worker cordoned
evicting pod eviction-005-drain/evict-sg-drain-...
error when evicting pods/... admission webhook "eviction.modelserving.volcano.sh"
denied the request: Eviction denied: protected by ModelServing evict-sg-drain.
Current ready groups (2) <= minAvailable (2).
...
error: unable to drain node "kind-worker" ... global timeout reached: 45s
```

Controller logs confirm the same behavior:

- `evict-sg-drain-0` roles entered `RoleDeleting`, then were recreated.
- `evict-sg-drain-1` and `evict-sg-drain-2` did not enter `RoleDeleting` during
  the drain.
- The tracker ConfigMap contains only:

  ```text
  ServingGroup/eviction-005-drain/evict-sg-drain/evict-sg-drain-0
  ```

Conclusion from logs: with the current local source and eviction webhook enabled,
the reported same-node case does not reproduce. ServingGroup protection keeps two
ready groups and blocks eviction of the second and third ServingGroups.

### Multi-Replica Webhook Reproduction

The missing condition was `kthena-controller-manager` with two replicas using the
older `dev-006` image.

Deployed:

```text
workload.controllerManager.replicas=2
image: kthena-controller-manager:dev-006
--enable-eviction-webhook=true
```

Verified two webhook backends:

```text
kthena-controller-manager-84bbb967f-45xgf   Ready   kind-worker
kthena-controller-manager-84bbb967f-tx6df   Ready   kind-worker2
```

Created `evict-sg-dev006-r2` in `eviction-005-dev006-r2` with all six business
Pods on `kind-worker`:

```text
evict-sg-dev006-r2-0-decode-0-0    kind-worker
evict-sg-dev006-r2-0-prefill-0-0   kind-worker
evict-sg-dev006-r2-1-decode-0-0    kind-worker
evict-sg-dev006-r2-1-prefill-0-0   kind-worker
evict-sg-dev006-r2-2-decode-0-0    kind-worker
evict-sg-dev006-r2-2-prefill-0-0   kind-worker
```

Ran:

```bash
kubectl drain kind-worker \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --pod-selector=modelserving.volcano.sh/name=evict-sg-dev006-r2 \
  --timeout=45s
kubectl uncordon kind-worker
```

Observed drain output:

```text
pod/evict-sg-dev006-r2-0-prefill-0-0 evicted
pod/evict-sg-dev006-r2-1-decode-0-0 evicted
pod/evict-sg-dev006-r2-0-decode-0-0 evicted
pod/evict-sg-dev006-r2-1-prefill-0-0 evicted
...
Eviction denied: protected by ModelServing evict-sg-dev006-r2.
Current ready groups (1) <= minAvailable (2).
```

Controller logs/events confirm two ServingGroups were disrupted:

```text
Role prefill/prefill-0 in ServingGroup evict-sg-dev006-r2-0 is now Deleting
Role decode/decode-0 in ServingGroup evict-sg-dev006-r2-0 is now Deleting
Role decode/decode-0 in ServingGroup evict-sg-dev006-r2-1 is now Deleting
Role prefill/prefill-0 in ServingGroup evict-sg-dev006-r2-1 is now Deleting
```

There was no shared tracker ConfigMap in the namespace:

```text
kubectl get cm -n eviction-005-dev006-r2
NAME               DATA   AGE
kube-root-ca.crt   1      ...
```

Conclusion: the bug reproduces when `pods/eviction` requests are load-balanced
across two controller-manager webhook replicas that do not share an atomic
disruption tracker. Each replica can make its decision from its local informer
state before seeing the other replica's admitted eviction, so more than one
ServingGroup can be admitted and `minAvailable: 2` is breached.

## Current Assessment

The observed "protection failed" condition reproduces with two controller-manager
webhook replicas on the older `dev-006` image. It does not reproduce with the
current local source image `dev-005`, which creates a per-ModelServing shared
ConfigMap tracker and uses it to serialize budget consumption across webhook
replicas.

No implementation code has been changed in this task yet. The likely fix is to
keep the ConfigMap-backed logical disruption tracker and ensure all supported
deployments use the shared tracker path whenever `replicas > 1`.

## Status

Verification completed. The bug is reproduced for `dev-006` with two webhook
replicas and is not reproduced for the current local source with the shared
ConfigMap tracker.
