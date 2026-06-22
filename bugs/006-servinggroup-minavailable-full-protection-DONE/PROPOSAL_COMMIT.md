# Proposal: Deny fail-open paths for full ServingGroup protection

## Branch

- Base branch: `fix/005-servinggroup-eviction-protection`
- Fix branch: `fix/006-servinggroup-minavailable-full-protection`

The eviction webhook implementation is still on top of
`feat/006-modelserving-eviction-budget-rework`, not upstream `main`.

## Characterization

The threshold comparison in the current ServingGroup path is correct for this
case:

```text
allow only when readyGroups > minAvailable
```

For `replicas: 3` and `minAvailable: 3`, a fully synced cache with three Ready
ServingGroups gives `3 > 3 == false`, so the first eviction is denied.

The likely bypass is a cache consistency fail-open:

1. `Handle` may resolve the target Pod through a live API GET when the Pod
   lister misses it.
2. `checkEvictionWithTracker` still builds `allPods` only from the Pod lister.
3. `checkServingGroupProtection` allows when the target ServingGroup is not
   observed in that lister-derived `allPods` set.
4. In that state the target Pod is known and labeled, but its ServingGroup is
   treated as "not observed", so the eviction can bypass `minAvailable: 3`.

This is especially visible when the allowed first eviction is the bug: with
`minAvailable: 3`, no tracker entry should ever be recorded because no first
ServingGroup disruption is permitted.

### Follow-up User Reproduction: `minAvailable: 2` burst drain

The user later reproduced a separate failure in a non-local environment with:

```text
replicas: 3
protectionLevel: ServingGroup
minAvailable: 2
```

All six ModelServing Pods were on the drained node:

```text
ms-eviction-test-{0,1,2}-{prefill,decode}-0-0
```

Expected behavior:

- one ServingGroup may be disrupted;
- other ServingGroups should be denied until the first disrupted ServingGroup is
  recovered and Ready again;
- Pods belonging to the same already-disrupted ServingGroup may continue to be
  evicted so drain can finish clearing that logical unit.

Observed behavior:

- the first denial happened only for `ms-eviction-test-0-prefill-0-0`;
- the other ServingGroups were effectively evicted/recreated together;
- final `kubectl get pods -owide` showed all six Pods recreated on another node.

Important controller-manager log sequence:

```text
05:40:05.865 ... pod=ms-eviction-test-2-decode-0-0 readyGroups=3 minAvailable=2 allowed=true trackerEntries=0 resourceVersion=27282282 unit=...ms-eviction-test-2
05:40:05.865 ... pod=ms-eviction-test-2-prefill-0-0 readyGroups=3 minAvailable=2 allowed=true trackerEntries=0 resourceVersion=27282282 unit=...ms-eviction-test-2
05:40:05.865 ... pod=ms-eviction-test-0-prefill-0-0 readyGroups=3 minAvailable=2 allowed=true trackerEntries=0 resourceVersion=27282282 unit=...ms-eviction-test-0
05:40:05.890 ... Updated tracker ... entries=1 keys=[...ms-eviction-test-2]
05:40:05.890 ... Failed to update tracker ... conflict
05:40:05.914 ... retry pod=ms-eviction-test-0-prefill-0-0 readyGroups=2 minAvailable=2 allowed=false
05:40:10.924 ... pod=ms-eviction-test-0-prefill-0-0 targetReady=false readyGroups=0 minAvailable=2 allowed=true reason="target group is already not ready"
```

This shows two correctness gaps:

1. Several concurrent admission requests can all make the allow/deny decision
   from the same stale ConfigMap `resourceVersion` before any tracker write is
   visible. `resourceVersion` conflict retry protects only requests whose
   tracker update conflicts; requests that already received a successful
   AdmissionReview allow response cannot be revoked.
2. The current "target group is already not ready" path always allows and does
   not distinguish between the same already-tracked disruption unit and an
   untracked group that became not-ready because the burst drain already caused
   additional damage. Once several Pods are terminating, retries can observe
   `readyGroups=0` and still allow more eviction.

## Proposed Fix

Make ServingGroup protection fail closed for all paths that cannot prove the
target eviction is within budget or belongs to the same already-authorized
disruption unit.

Implementation options to evaluate:

- Preferred: merge the live-resolved target Pod into the `allPods` slice before
  evaluating protection when it is missing from the lister result. This keeps the
  normal lister path fast and prevents the target group from being invisible.
- Also add a defensive deny path in `checkServingGroupProtection`: if the target
  Pod has a non-empty ServingGroup label and the target group is not observed,
  deny instead of allow unless the API server confirms the Pod no longer exists.
- Tighten the "target group already not ready" allow path:
  - allow only when the target group has an active tracker entry, meaning a prior
    allowed request explicitly consumed budget for this logical unit;
  - deny an untracked not-ready target group when the ready group count is at or
    below `minAvailable`, because this state means the budget is already
    exhausted or the cache observed external damage.
- Add a same-process keyed mutex around the per-ModelServing tracker
  read/decision/update section. The ConfigMap `resourceVersion` remains the
  cross-replica guard, but the local mutex prevents one controller-manager
  process from returning multiple allow responses before its first tracker write
  is visible to sibling goroutines.
- Consider whether Helm should force `controllerManager.replicas=1` while this
  webhook is enabled. Without an external transactional admission primitive,
  ConfigMap compare-and-swap cannot revoke concurrently returned allow
  responses from different webhook Pods.

The preferred implementation is less conservative and preserves normal eviction
for unmanaged or truly deleted Pods, while still ensuring a known labeled target
cannot bypass the budget because of cache lag.

## Test Plan

Add targeted unit tests in
`pkg/model-serving-controller/webhook/eviction_handler_test.go`:

- `ServingGroup` with `replicas: 3`, two roles per group, and
  `minAvailable: 3`; all six Pods Ready; the first eviction is denied.
- Cache-lag case: target Pod exists in the API client and has ModelServing/group
  labels, but is absent from the lister snapshot; eviction is denied or evaluated
  after merging the target Pod, never allowed via "target group not observed".
- Existing `minAvailable: 2` tests continue to allow eviction within one tracked
  ServingGroup and deny another group while budget is exhausted.
- Concurrent burst case: start multiple goroutines evicting Pods from three
  different ServingGroups with `replicas: 3` and `minAvailable: 2`; assert only
  one ServingGroup is allowed and other groups are denied.
- Already-not-ready untracked case: mark an untracked target group not ready
  while ready groups are at or below `minAvailable`; assert eviction is denied.
- Already-not-ready tracked case: after one Pod from a group consumes the
  tracker, evict another Pod from the same group; assert eviction is allowed.

Run from `kthena/`:

```bash
go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandler'
go test ./pkg/model-serving-controller/webhook
go test ./...
```

## Manual Verification Plan

Use `reproduce-multirole-servinggroup-minavailable3.yaml`:

```bash
kubectl apply -f ../issues/bugs/006-servinggroup-minavailable-full-protection-IP/reproduce-multirole-servinggroup-minavailable3.yaml
kubectl get pod -n eviction-006-minavailable3 \
  -l modelserving.volcano.sh/name=evict-sg-minavailable3 -o wide
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=45s
```

Expected result:

```text
Eviction denied: protected by ModelServing evict-sg-minavailable3.
Current ready groups (3) <= minAvailable (3).
```

No Pod from the ModelServing should be evicted.

## Verification Results

### Implementation: fail closed for untracked unavailable units

Implemented in `pkg/model-serving-controller/webhook/eviction_handler.go`:

- Added a per-ModelServing in-process mutex around the tracker
  read/decision/update section to avoid multiple same-process admission
  goroutines consuming budget from the same stale tracker snapshot.
- Merged the live-resolved target Pod into the lister-derived `allPods` snapshot
  before budget evaluation, so a target Pod found by API fallback cannot be
  invisible to ServingGroup accounting.
- Changed ServingGroup handling:
  - a target group that is not observed is denied instead of allowed;
  - a target group that is not ready is allowed only when it has an active
    tracker entry or there are still more ready groups than `minAvailable`;
  - untracked not-ready target groups at or below `minAvailable` are denied.
- Extended tracker entries to record the Pod UID that first consumed the
  logical-unit budget. When a tracked logical unit is fully Ready again and that
  trigger Pod UID is no longer present, the tracker entry is cleaned immediately
  instead of waiting for the TTL. This lets node drain proceed one ServingGroup
  at a time as soon as the replacement group is Ready.
- Applied the same defensive shape to Role protection for consistency: missing
  or untracked unavailable role instances no longer unconditionally fail open.

Added `pkg/model-serving-controller/webhook/eviction_handler_test.go` coverage:

- same tracked ServingGroup can continue draining its second Pod;
- untracked not-ready ServingGroup at `minAvailable` is denied;
- target Pod missing from the lister snapshot is merged/evaluated and denied for
  `minAvailable == replicas`;
- concurrent burst eviction of six Pods across three ServingGroups with
  `replicas: 3` and `minAvailable: 2` allows exactly one ServingGroup and denies
  the other two.
- recovered ServingGroup tracker entries are cleaned when replacement Pods are
  Ready and the originally evicted Pod UID is absent.

### Unit Tests After Implementation

From `kthena/`:

```bash
go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandler'
go test ./pkg/model-serving-controller/webhook
go test $(go list ./... | grep -v /e2e | grep -v /client-go)
```

Results:

- `go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandler'`
  passed.
- `go test ./pkg/model-serving-controller/webhook` passed.
- The non-e2e/client-go package suite passed after running with local port and Go
  module cache permissions.
- Per user direction, validation moved to local Kind image testing instead of
  running Go e2e tests.

### Kind Image Verification: `replicas=3`, `minAvailable=2`

Added verification manifest:

```text
issues/bugs/006-servinggroup-minavailable-full-protection-IP/reproduce-kind-minavailable2-drain.yaml
```

Environment:

- Context: `kind-kind`
- Cluster nodes: `kind-control-plane`, `kind-worker`, `kind-worker2`
- Node architecture: `arm64`
- Controller image: `kthena-controller-manager:dev-006-minavailable-fix`
- Helm release: `kthena`, namespace `kthena-system`
- Eviction webhook args verified on the Deployment:
  `--enable-eviction-webhook=true`, `--eviction-tracker-ttl=60s`

Build and deploy:

```bash
GOOS=linux GOARCH=arm64 go build -o ../local-output/kthena-controller-manager ./cmd/kthena-controller-manager/main.go
docker build -t kthena-controller-manager:dev-006-minavailable-fix -f Dockerfile.local --build-arg BINARY_DIR=local-output --build-arg BINARY_NAME=kthena-controller-manager .
kind load docker-image kthena-controller-manager:dev-006-minavailable-fix --name kind
helm upgrade --install kthena ./charts/kthena --namespace kthena-system --create-namespace --set workload.controllerManager.image.repository=kthena-controller-manager --set workload.controllerManager.image.tag=dev-006-minavailable-fix --set workload.controllerManager.image.pullPolicy=IfNotPresent --set workload.controllerManager.evictionWebhook.enabled=true
kubectl rollout status deployment/kthena-controller-manager -n kthena-system --timeout=120s
```

Applied:

```bash
kubectl apply -f ../issues/bugs/006-servinggroup-minavailable-full-protection-IP/reproduce-kind-minavailable2-drain.yaml
kubectl wait pod -n eviction-006-kind-minavailable2 -l modelserving.volcano.sh/name=evict-sg-minavailable2-kind --for=condition=Ready --timeout=180s
```

Pre-drain state:

```text
evict-sg-minavailable2-kind-0-decode-0-0    1/1 Running kind-worker
evict-sg-minavailable2-kind-0-prefill-0-0   1/1 Running kind-worker
evict-sg-minavailable2-kind-1-decode-0-0    1/1 Running kind-worker
evict-sg-minavailable2-kind-1-prefill-0-0   1/1 Running kind-worker
evict-sg-minavailable2-kind-2-decode-0-0    1/1 Running kind-worker
evict-sg-minavailable2-kind-2-prefill-0-0   1/1 Running kind-worker
```

Triggered real drain:

```bash
kubectl drain kind-worker --ignore-daemonsets --delete-emptydir-data --timeout=60s --pod-selector=modelserving.volcano.sh/name=evict-sg-minavailable2-kind
```

Result:

- Drain cordoned `kind-worker`.
- Exactly one ServingGroup was evicted:
  - `evict-sg-minavailable2-kind-1-decode-0-0`
  - `evict-sg-minavailable2-kind-1-prefill-0-0`
- The other two ServingGroups were denied repeatedly until drain timed out:
  `Current ready groups (2) <= minAvailable (2)`.
- Pending pods at timeout were exactly group `0` and group `2`:
  - `evict-sg-minavailable2-kind-0-decode-0-0`
  - `evict-sg-minavailable2-kind-0-prefill-0-0`
  - `evict-sg-minavailable2-kind-2-decode-0-0`
  - `evict-sg-minavailable2-kind-2-prefill-0-0`

Tracker after drain:

```text
entries: '{"ServingGroup/eviction-006-kind-minavailable2/evict-sg-minavailable2-kind/evict-sg-minavailable2-kind-1":"2026-06-07T22:50:16.546534045Z"}'
```

Representative controller-manager log:

```text
22:49:16.546 allowed=true  group=evict-sg-minavailable2-kind-1 readyGroups=3 minAvailable=2 disruptionUnit=...kind-1
22:49:16.547 Updated tracker entries=1 keys=[...kind-1]
22:49:16.549 allowed=true  group=evict-sg-minavailable2-kind-1 reason="target group is already tracked as disrupted"
22:49:16.548 allowed=false group=evict-sg-minavailable2-kind-2 reason="Current ready groups (2) <= minAvailable (2)"
22:49:16.550 allowed=false group=evict-sg-minavailable2-kind-0 reason="Current ready groups (2) <= minAvailable (2)"
```

Post-verification recovery:

- Ran `kubectl uncordon kind-worker`.
- All six Pods returned to `Ready`.
- `kind-worker` returned to `Ready`.
- ModelServing `availableReplicas` returned to `3`.

### Corrected Kind Verification: rolling drain to another node

The first Kind run above used `nodeSelector: kind-worker`, which intentionally
pinned replacements to the drained node. That only proved the webhook would not
evict multiple ServingGroups at once; it did **not** prove the required rolling
behavior where one group is recreated on another node and then the next group is
allowed. Per user feedback, a second verification was run with no `nodeSelector`.

Added manifest:

```text
issues/bugs/006-servinggroup-minavailable-full-protection-IP/reproduce-kind-minavailable2-rolling-drain.yaml
```

Setup:

```bash
kubectl cordon kind-worker2
kubectl apply -f ../issues/bugs/006-servinggroup-minavailable-full-protection-IP/reproduce-kind-minavailable2-rolling-drain.yaml
kubectl wait pod -n eviction-006-kind-rolling -l modelserving.volcano.sh/name=evict-sg-rolling --for=condition=Ready --timeout=180s
```

Initial state:

```text
evict-sg-rolling-0-decode-0-0    1/1 Running kind-worker
evict-sg-rolling-0-prefill-0-0   1/1 Running kind-worker
evict-sg-rolling-1-decode-0-0    1/1 Running kind-worker
evict-sg-rolling-1-prefill-0-0   1/1 Running kind-worker
evict-sg-rolling-2-decode-0-0    1/1 Running kind-worker
evict-sg-rolling-2-prefill-0-0   1/1 Running kind-worker
```

Drain:

```bash
kubectl uncordon kind-worker2
kubectl drain kind-worker --ignore-daemonsets --delete-emptydir-data --timeout=300s --pod-selector=modelserving.volcano.sh/name=evict-sg-rolling
```

Observed behavior:

- Drain first allowed only one ServingGroup and denied the other groups with
  `Current ready groups (2) <= minAvailable (2)`.
- After the first group was recreated and Ready on `kind-worker2`, the tracker
  entry was cleaned before TTL expiry and the next ServingGroup was admitted.
- The sequence repeated for the final group.
- `kubectl drain` completed successfully with `node/kind-worker drained`.

Final state:

```text
evict-sg-rolling-0-decode-0-0    1/1 Running kind-worker2
evict-sg-rolling-0-prefill-0-0   1/1 Running kind-worker2
evict-sg-rolling-1-decode-0-0    1/1 Running kind-worker2
evict-sg-rolling-1-prefill-0-0   1/1 Running kind-worker2
evict-sg-rolling-2-decode-0-0    1/1 Running kind-worker2
evict-sg-rolling-2-prefill-0-0   1/1 Running kind-worker2
```

Post-verification:

- `kubectl uncordon kind-worker` restored the drained node.
- `kubectl get nodes` showed all Kind nodes `Ready`.
- ModelServing `availableReplicas` was `3`.

### Role-Level Kind Verification: per-ServingGroup role budget

Added manifest:

```text
issues/bugs/006-servinggroup-minavailable-full-protection-DONE/reproduce-kind-role-minavailable2-rolling-drain.yaml
```

Agreed Role semantics:

- For `protectionLevel: Role`, each role's available instances are checked
  within each individual ServingGroup.
- The protection dimension is `ServingGroup + Role`, not `ModelServing + Role`.
- A role instance identity is `groupName + role + roleID`.

The verification manifest uses three ServingGroups. Each ServingGroup has three
`prefill` role instances and three `decode` role instances:

```yaml
replicas: 3
rolloutStrategy:
  evictionStrategy:
    protectionLevel: Role
    minAvailable: 2
    roleMinAvailable:
      prefill: 2
      decode: 2
template:
  roles:
  - name: prefill
    replicas: 3
  - name: decode
    replicas: 3
```

Implementation correction:

- Role protection now only counts role instances in the target Pod's
  ServingGroup for the target role.
- `roleMinAvailable` is scaled against `role.replicas` inside one
  ServingGroup, not against `modelServing.replicas * role.replicas`.
- Existing tracker keys include `groupName + role + roleID`, so independent
  ServingGroups do not share the same role disruption budget.

Follow-up unit test:

```bash
go test ./pkg/model-serving-controller/webhook
```

Result: passed.

Valid Kind image verification used the same image tag
`kthena-controller-manager:dev-006-minavailable-fix`, rebuilt with the corrected
Role semantics, loaded into Kind, and installed with eviction webhook explicitly
enabled:

```bash
helm upgrade --install kthena ./charts/kthena \
  --namespace kthena-system \
  --create-namespace \
  --set workload.controllerManager.image.repository=kthena-controller-manager \
  --set workload.controllerManager.image.tag=dev-006-minavailable-fix \
  --set workload.controllerManager.image.pullPolicy=IfNotPresent \
  --set workload.controllerManager.evictionWebhook.enabled=true
```

Confirmed webhook configuration included:

```text
eviction.modelserving.volcano.sh  /validate-eviction  ["pods/eviction"]
```

Setup:

```bash
kubectl cordon kind-worker2
kubectl apply -f ../issues/bugs/006-servinggroup-minavailable-full-protection-DONE/reproduce-kind-role-minavailable2-rolling-drain.yaml
kubectl wait pod -n eviction-006-kind-role-rolling -l modelserving.volcano.sh/name=evict-role-rolling --for=condition=Ready --timeout=240s
```

Initial state: all 18 Pods were Ready on `kind-worker`.

```text
evict-role-rolling-{0,1,2}-prefill-{0,1,2}-0  1/1 Running kind-worker
evict-role-rolling-{0,1,2}-decode-{0,1,2}-0   1/1 Running kind-worker
```

Drain:

```bash
kubectl uncordon kind-worker2
kubectl drain kind-worker --ignore-daemonsets --delete-emptydir-data --timeout=420s --pod-selector=modelserving.volcano.sh/name=evict-role-rolling
```

Observed behavior:

- For each ServingGroup and each role, one role instance could be disrupted
  while two role instances remained available.
- Additional instances in the same `ServingGroup + Role` were denied until a
  replacement became Ready on `kind-worker2`.
- Denials were scoped to the concrete ServingGroup and role:

```text
ServingGroup evict-role-rolling-0 role prefill ready instances (2) <= minAvailable (2)
ServingGroup evict-role-rolling-0 role decode ready instances (2) <= minAvailable (2)
ServingGroup evict-role-rolling-1 role prefill ready instances (2) <= minAvailable (2)
ServingGroup evict-role-rolling-1 role decode ready instances (2) <= minAvailable (2)
ServingGroup evict-role-rolling-2 role prefill ready instances (2) <= minAvailable (2)
ServingGroup evict-role-rolling-2 role decode ready instances (2) <= minAvailable (2)
```

- After replacement role instances became Ready on `kind-worker2`, the next
  instance in that same `ServingGroup + Role` budget was admitted.
- The sequence continued until `kubectl drain` completed with
  `node/kind-worker drained`.

Intermediate state confirmed rolling progress:

```text
evict-role-rolling-0-decode-0-0    1/1 Running       kind-worker
evict-role-rolling-0-decode-2-0    1/1 Terminating   kind-worker
evict-role-rolling-0-decode-3-0    1/1 Running       kind-worker2
evict-role-rolling-0-prefill-0-0   1/1 Running       kind-worker
evict-role-rolling-0-prefill-2-0   1/1 Terminating   kind-worker
evict-role-rolling-0-prefill-3-0   1/1 Running       kind-worker2
```

Final state: all 18 Pods were Ready on `kind-worker2`.

```text
evict-role-rolling-{0,1,2}-prefill-*  1/1 Running kind-worker2
evict-role-rolling-{0,1,2}-decode-*   1/1 Running kind-worker2
```

Post-verification:

- ModelServing `availableReplicas` was `3`.
- `kubectl uncordon kind-worker` restored the drained node.
- `kubectl get nodes` showed all Kind nodes `Ready`.

### Kind Reproduction Attempt: Stable Synced Cache

Environment:

- Date: `2026-06-07T20:07:58Z`
- Cluster: local Kind, Kubernetes `v1.35.0`
- Controller image: `kthena-controller-manager:dev-005-logs-fix`
- Controller replicas: `2`
- Webhook: `eviction.modelserving.volcano.sh`, `failurePolicy=Fail`

Applied:

```bash
kubectl apply -f ../issues/bugs/006-servinggroup-minavailable-full-protection-IP/reproduce-multirole-servinggroup-minavailable3.yaml
```

Observed all six Pods Ready on `kind-worker`:

```text
evict-sg-minavailable3-0-decode-0-0    1/1 Running kind-worker
evict-sg-minavailable3-0-prefill-0-0   1/1 Running kind-worker
evict-sg-minavailable3-1-decode-0-0    1/1 Running kind-worker
evict-sg-minavailable3-1-prefill-0-0   1/1 Running kind-worker
evict-sg-minavailable3-2-decode-0-0    1/1 Running kind-worker
evict-sg-minavailable3-2-prefill-0-0   1/1 Running kind-worker
```

Triggered drain:

```bash
kubectl drain kind-worker \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=45s \
  --pod-selector=modelserving.volcano.sh/name=evict-sg-minavailable3
```

Result: stable synced-cache path did **not** reproduce the reported eviction.
Every eviction request was denied and drain timed out.

Representative client error:

```text
admission webhook "eviction.modelserving.volcano.sh" denied the request:
Eviction denied: protected by ModelServing evict-sg-minavailable3.
Current ready groups (3) <= minAvailable (3).
```

Representative controller-manager log:

```text
ServingGroup eviction state modelServing=eviction-006-minavailable3/evict-sg-minavailable3
pod=eviction-006-minavailable3/evict-sg-minavailable3-0-prefill-0-0
targetGroup="evict-sg-minavailable3-0" targetFound=true targetReady=true
readyGroups=3 observedGroups=3 totalReplicas=3 minAvailable=3 allowed=false
groupStates=[
  evict-sg-minavailable3-0(pods=2,ready=true,tracked=false)
  evict-sg-minavailable3-1(pods=2,ready=true,tracked=false)
  evict-sg-minavailable3-2(pods=2,ready=true,tracked=false)
]
```

Tracker state after the drain attempt:

```text
data:
  entries: '{}'
```

All six Pods remained `Running`.

Conclusion from this run:

- The steady-state threshold logic works on the currently deployed image.
- The reported real eviction is likely tied to a timing/cache path, deployment
  version difference, or a target group already being considered not-ready.
- Continue investigation by forcing controller-manager cache churn or using the
  user's exact controller image/logs before changing implementation code.

### Kind Reproduction Attempt: Fast Drain After Pod Ready

Added `reproduce-multirole-servinggroup-minavailable3-fast.yaml` with the same
shape and a distinct namespace/name. Applied at `2026-06-07T20:10:45Z`.

Pods reached Ready at age ~8s. Immediately triggered:

```bash
kubectl drain kind-worker \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=30s \
  --pod-selector=modelserving.volcano.sh/name=evict-sg-minavailable3-fast
```

Result: also did **not** reproduce the reported eviction. Drain timed out with
all six Pods still `Running`.

Tracker state:

```text
data:
  entries: '{}'
```

Representative controller-manager log:

```text
ServingGroup eviction state modelServing=eviction-006-minavailable3-fast/evict-sg-minavailable3-fast
pod=eviction-006-minavailable3-fast/evict-sg-minavailable3-fast-2-prefill-0-0
targetGroup="evict-sg-minavailable3-fast-2" targetFound=true targetReady=true
readyGroups=3 observedGroups=3 totalReplicas=3 minAvailable=3 allowed=false
groupStates=[
  evict-sg-minavailable3-fast-0(pods=2,ready=true,tracked=false)
  evict-sg-minavailable3-fast-1(pods=2,ready=true,tracked=false)
  evict-sg-minavailable3-fast-2(pods=2,ready=true,tracked=false)
]
Eviction tracker decision ... trackerEntries=0 trackerKeys=[] allPods=6 disruptionUnit=""
```

Conclusion from both Kind attempts:

- Current deployed image `dev-005-logs-fix` denies the `minAvailable: 3` case
  when informer caches can list all six Pods.
- The local reproduction has not produced `target group not observed`,
  `ModelServing not found`, `allPods<6`, or an allowed tracker write.
- The next useful reproduction needs the exact user-side logs/image or an
  intentionally forced controller-manager cache churn window.

### User Reproduction Record

The user provided a previous drain transcript for
`eviction-005-dev005/evict-sg-dev005`. That manifest does **not** set
`nodeSelector`; it uses natural scheduling:

```yaml
spec:
  replicas: 3
  schedulerName: volcano
  rolloutStrategy:
    evictionStrategy:
      protectionLevel: ServingGroup
      minAvailable: 3
```

Important observation from the transcript:

```text
pod/evict-sg-dev005-2-decode-0-0 evicted
pod/evict-sg-dev005-2-prefill-0-0 evicted
```

After those two Pods were evicted, retries for the remaining Pods were denied:

```text
Eviction denied: protected by ModelServing evict-sg-dev005.
Current ready groups (2) <= minAvailable (3).
```

This means the bug in that run was the first disrupted ServingGroup being
allowed despite `minAvailable: 3`. Once one ServingGroup was lost, the webhook
correctly observed only two ready groups and denied additional groups.

### Kind Reproduction Attempt: Natural Scheduling, Cross-Node Roles

Added `reproduce-multirole-servinggroup-minavailable3-natural.yaml` with no
`nodeSelector`, matching the user's manifest shape.

Natural placement:

```text
evict-sg-minavailable3-natural-0-decode-0-0    kind-worker
evict-sg-minavailable3-natural-0-prefill-0-0   kind-worker2
evict-sg-minavailable3-natural-1-decode-0-0    kind-worker2
evict-sg-minavailable3-natural-1-prefill-0-0   kind-worker
evict-sg-minavailable3-natural-2-decode-0-0    kind-worker
evict-sg-minavailable3-natural-2-prefill-0-0   kind-worker2
```

Drained `kind-worker` for this ModelServing's Pods:

```bash
kubectl drain kind-worker \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --timeout=45s \
  --pod-selector=modelserving.volcano.sh/name=evict-sg-minavailable3-natural
```

Result: no Pod was evicted. All three target Pods were denied with:

```text
Current ready groups (3) <= minAvailable (3)
```

Representative log:

```text
targetFound=true targetReady=true readyGroups=3 observedGroups=3
totalReplicas=3 minAvailable=3 allowed=false
trackerEntries=0 trackerKeys=[] allPods=6 disruptionUnit=""
```

Then drained `kind-worker2` for the counterpart Pods with the same selector.
Result was also no eviction. Logs again showed:

```text
readyGroups=3 observedGroups=3 totalReplicas=3 minAvailable=3 allowed=false
allPods=6 trackerEntries=0
```

Conclusion:

- The no-`nodeSelector` natural scheduling shape is now covered locally.
- Current deployed image still does not reproduce the user's first-group allow.
- The user transcript is consistent with an older or different code path where
  the first target ServingGroup was treated as already not-ready or not observed,
  then subsequent requests saw `readyGroups=2` and were denied.

## Associated Commits

- Commit ID: pending
- Branch: `fix/006-servinggroup-minavailable-full-protection`
