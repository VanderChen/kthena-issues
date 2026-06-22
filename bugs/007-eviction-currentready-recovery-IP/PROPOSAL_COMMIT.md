# Proposal: Refresh eviction currentReady after ServingGroup recovery

## Branch

- Current workspace branch: `fix/007-eviction-currentready-recovery`
- Base branch: `fix/006-servinggroup-minavailable-full-protection`

The eviction webhook implementation is now present in the checked-out fix branch
at:

```text
pkg/model-serving-controller/webhook/eviction_handler.go
```

## Characterization

The current fix branch computes readiness from two inputs:

1. `allPods` from the Pod informer lister, with the target Pod merged in when it
   was found through a live API GET.
2. ConfigMap-backed disruption tracker entries.

ServingGroup readiness is effectively:

```text
ready = no active tracker entry for the group && all observed group Pods are Ready
```

The fix branch added `cleanupRecoveredDisruptionEntries(entries, allPods)`, which
removes a tracker entry when:

- the entry has a `triggerPodUID`;
- the corresponding unit's observed Pods are all Ready;
- the originally evicted Pod UID is no longer present.

That is the right direction, but it still depends entirely on the informer-backed
`allPods` snapshot. If the cache is stale in either direction, the webhook can
make a wrong `currentReady` decision:

- If the recovered replacement Pods are not yet visible in the informer cache,
  the unit is not considered fully Ready and the tracker entry remains active.
- If the old trigger Pod is still visible in the informer cache even after the
  replacement is Ready, `hasPodUID(unitPods, triggerPodUID)` prevents cleanup,
  so the unit continues to reduce `currentReady`.
- A second eviction immediately after the first recovery can therefore see
  `currentReady` below the real cluster state and deny even though the workload
  has recovered.

This makes `currentReady` a function of cache convergence and tracker TTL rather
than the best available Kubernetes state.

## Kind Reproduction Results

### Environment

- Date: 2026-06-17
- Context: `kind-kind`
- Controller-manager image in cluster:
  `kthena-controller-manager:dev-006-eviction-role-minavailable-v2`
- Controller-manager args:
  `--enable-eviction-webhook=true`, `--eviction-tracker-ttl=60s`
- Webhook: `eviction.modelserving.volcano.sh`, path `/validate-eviction`,
  `failurePolicy: Fail`
- Fix branch checked out locally:
  `fix/007-eviction-currentready-recovery`

Added reproduction artifacts:

```text
issues/bugs/007-eviction-currentready-recovery-IP/reproduce-kind-currentready-recovery.yaml
issues/bugs/007-eviction-currentready-recovery-IP/reproduce-kind-currentready.yaml
issues/bugs/007-eviction-currentready-recovery-IP/evict-group0-prefill.json
issues/bugs/007-eviction-currentready-recovery-IP/evict-group1-prefill.json
issues/bugs/007-eviction-currentready-recovery-IP/evict-group2-prefill.json
issues/bugs/007-eviction-currentready-recovery-IP/stale-tracker-group0-patch.json
issues/bugs/007-eviction-currentready-recovery-IP/kind-same-name-stale-tracker-no-owner.yaml
issues/bugs/007-eviction-currentready-recovery-IP/kind-same-name-stale-tracker-patch.json
issues/bugs/007-eviction-currentready-recovery-IP/kind-same-name-stale-pod.yaml
issues/bugs/007-eviction-currentready-recovery-IP/kind-same-name-orphan-notready-pod.yaml
issues/bugs/007-eviction-currentready-recovery-IP/kind-current-owner-empty-tracker.yaml
```

Workload:

```text
namespace: eviction-007-currentready
ModelServing: evict-currentready
replicas: 3
roles per ServingGroup: prefill, decode
protectionLevel: ServingGroup
minAvailable: 2
```

### Natural recovery window

Ran the normal sequence:

1. Evict `evict-currentready-0-prefill-0-0`.
2. Wait for the replacement Pod to become Ready.
3. Immediately evict `evict-currentready-1-prefill-0-0`.

The natural Kind run did not reproduce a false denial. The webhook cleaned the
first tracker entry before the second decision:

```text
09:48:51.698 ... Update ServingGroup evict-currentready-0 status to Running
09:48:51.803 ... Cleaned eviction tracker entries ... entriesBefore=1 entriesAfter=0
09:48:51.803 ... targetGroup="evict-currentready-1" ... readyGroups=3 ... allowed=true
```

This confirms the happy path works when the informer snapshot has converged.

### Controlled stale tracker/cache reproduction

To model the reported cache/tracker stale outcome, all Pods were first confirmed
Ready:

```text
NAME                               UID                                    GROUP                  ROLE      READY
evict-currentready-0-decode-0-0    5f5a2f36-e5ca-4224-8047-e3349a253ff9   evict-currentready-0   decode    true
evict-currentready-0-prefill-0-0   3f1f8bf9-dc78-4865-a061-e9bf14ec8365   evict-currentready-0   prefill   true
evict-currentready-1-decode-0-0    79ee7b2c-2093-46ae-8ae9-974bf1a1519f   evict-currentready-1   decode    true
evict-currentready-1-prefill-0-0   5a6503a1-c291-41fb-a8fa-d5578712e0ab   evict-currentready-1   prefill   true
evict-currentready-2-decode-0-0    f731727c-46d1-4f8e-bb01-606c9c564ec0   evict-currentready-2   decode    true
evict-currentready-2-prefill-0-0   8269d059-a2a8-4297-b522-9e84913ef033   evict-currentready-2   prefill   true
```

ModelServing status also reported Ready:

```text
availableReplicas: 3
conditions:
- message: All Serving groups are ready
  reason: AllGroupsReady
  status: "True"
  type: Available
```

Then the tracker ConfigMap was patched with an active entry for the already
Ready group `evict-currentready-0`. This is a controlled injection of the stale
state the webhook would see if its tracker/cache view still considered the
recovered unit disrupted; it is not a natural cache-staleness reproduction by
itself.

```text
entries: '{"ServingGroup/eviction-007-currentready/evict-currentready/evict-currentready-0":{"expiresAt":"2026-06-17T10:30:00Z","triggerPodUID":"3f1f8bf9-dc78-4865-a061-e9bf14ec8365","triggerPodName":"evict-currentready-0-prefill-0-0"}}'
```

Evicting `evict-currentready-2-prefill-0-0` was denied:

```text
Error from server: admission webhook "eviction.modelserving.volcano.sh" denied the request: Eviction denied: protected by ModelServing evict-currentready. Current ready groups (2) <= minAvailable (2).
```

Controller-manager log:

```text
09:53:19.386 ... targetGroup="evict-currentready-2" targetFound=true targetReady=true readyGroups=2 observedGroups=3 totalReplicas=3 minAvailable=2 allowed=false reason="Eviction denied: protected by ModelServing evict-currentready. Current ready groups (2) <= minAvailable (2)." groupStates=[evict-currentready-0(pods=2,ready=false,tracked=true) evict-currentready-1(pods=2,ready=true,tracked=false) evict-currentready-2(pods=2,ready=true,tracked=false)]
09:53:19.386 ... trackerEntries=1 trackerKeys=[ServingGroup/eviction-007-currentready/evict-currentready/evict-currentready-0] allPods=6 disruptionUnit=""
```

This reproduces the strongest stale-tracker shape: Kubernetes and ModelServing
state prove all groups are Ready, but `currentReady` remains 2 because an active
tracker entry wins over observed readiness. This injected entry used the current
Pod UID, so the final implementation intentionally does not clear this exact
state; clearing it would also forget a just-allowed eviction before the API
server has removed the original Pod. The implementation instead targets the
real recovery case where the tracker references an old trigger UID and the live
API can prove that UID is gone.

## Proposed Fix

Make tracker recovery cleanup use refreshed unit state when the cached snapshot
is inconclusive.

Implementation outline:

- Keep the informer snapshot as the fast path.
- When an active tracker entry prevents a unit from being counted ready, inspect
  whether the cached Pods for that unit are inconclusive:
  - no Pods are observed for the unit;
  - some expected Pods for the unit are missing;
  - the trigger Pod UID is still observed even though replacement Pods may have
    been created;
  - any observed Pod is not Ready while the tracker entry is the only reason
    blocking budget recovery.
- For inconclusive units, perform a live API list for Pods matching the
  ModelServing labels in the namespace, then filter to the disruption unit.
- Remove the tracker entry when live state proves:
  - the unit has the expected Pods for that logical unit;
  - all unit Pods are Ready and not deleting;
  - the original trigger Pod UID is absent.
- Keep the trigger UID absence requirement for normal entries so a just-allowed
  eviction cannot be immediately forgotten before the API server has deleted the
  Pod. The important change is that the absence check should use a refreshed live
  Pod list when the cached snapshot may still contain the old trigger Pod.
- Recompute `currentReady` after cleanup using the refreshed unit snapshot, so
  the recovered unit contributes to the current admission decision instead of
  waiting for the next request or TTL.
- Apply the same recovery path to both ServingGroup and Role protection.

This keeps normal admission decisions on the informer path, but allows the
webhook to repair stale tracker state when it is about to affect the budget.

## Expected Unit Tests

Add focused tests in:

```text
pkg/model-serving-controller/webhook/eviction_handler_test.go
```

Test cases:

- ServingGroup tracker recovery with stale old Pod UID in the informer cache:
  live API state has replacement Ready Pods and no trigger UID; a second
  ServingGroup eviction is allowed because `currentReady` recovers.
- ServingGroup tracker recovery when replacement Pods are missing from the
  informer cache but present and Ready in live API state.
- ServingGroup does not clear the tracker when live API state still contains the
  trigger Pod UID or the replacement unit is not fully Ready.
- Role protection mirrors the same behavior for `groupName/role/roleID`.
- Existing tests for burst protection and untracked not-ready denial remain
  unchanged.

Run from `kthena/` after implementation:

```bash
go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandler'
go test ./pkg/model-serving-controller/webhook
go test ./...
```

## Manual Verification Plan

Use a local Kind cluster with the eviction webhook enabled.

Scenario:

1. Deploy a ModelServing with `replicas: 3`,
   `protectionLevel: ServingGroup`, and `minAvailable: 2`.
2. Evict one ServingGroup Pod and confirm the webhook records a tracker entry.
3. Wait for the ServingGroup replacement Pods to become Ready.
4. Immediately evict a Pod from another ServingGroup.

Expected result:

- Logs show the recovered first ServingGroup tracker entry is cleaned before the
  second decision.
- The second eviction sees `currentReady=3` and is allowed when it should be
  within budget.
- A second eviction while the first group is still not Ready remains denied.

Useful log patterns:

```text
ServingGroup eviction state
Cleaned eviction tracker entries
Current ready groups
target group is already tracked
```

## Approval Gate

Approved by the user on 2026-06-17 after the Kind reproduction and proposal.

## Verification Results

### Implementation

Implemented in `pkg/model-serving-controller/webhook/eviction_handler.go`:

- Kept the existing informer-only cleanup fast path.
- Added a live Pod refresh path for active tracker entries that could not be
  cleaned from cache because the cached unit is empty, not Ready, or still
  contains the trigger UID.
- The live refresh lists Pods for the ModelServing directly from the API server,
  re-runs recovered-entry cleanup, and uses the refreshed Pod snapshot for the
  current admission decision when cleanup succeeds.
- The trigger UID absence requirement is preserved. A just-allowed eviction is
  still protected until the API server no longer reports the original trigger
  Pod UID, which avoids reintroducing the burst-drain bug fixed in 006.

Added tests in `pkg/model-serving-controller/webhook/eviction_handler_test.go`:

- `TestEvictionHandlerRefreshesLivePodsForRecoveredServingGroupTracker`
  verifies stale cache with old trigger UID is repaired by live Pod refresh and
  the next ServingGroup eviction is allowed.
- `TestEvictionHandlerKeepsServingGroupTrackerWhenLivePodsStillContainTriggerUID`
  verifies the tracker is not cleared while live API still contains the trigger
  UID, preserving immediate burst protection.
- `TestEvictionHandlerRefreshesLivePodsForRecoveredRoleTracker` verifies the
  same stale-cache recovery path for Role protection entries identified by
  `groupName/role/roleID`.
- `TestEvictionHandlerResetsTrackerFromPreviousSameNamedModelServing` verifies
  a tracker ConfigMap left by a deleted same-name ModelServing is reset and
  rebound to the current ModelServing UID before admission uses it.
- `TestEvictionHandlerIgnoresPodsFromPreviousSameNamedModelServing` verifies
  Pods owned by a previous same-name ModelServing UID do not reduce the current
  object's `currentReady`.
- `TestEvictionHandlerAllowsPodFromPreviousSameNamedModelServing` verifies
  evicting an old-lifecycle Pod is allowed without writing disruption state into
  the current same-name ModelServing tracker.

Same-name delete/recreate hardening:

- Target Pods are only protected when their ownerReference points at the current
  ModelServing UID. Old-lifecycle Pods with the same name label are allowed and
  do not consume the new object's eviction budget.
- Cached and live Pod lists are filtered to the current ModelServing UID before
  computing ServingGroup or Role readiness.
- Existing tracker ConfigMaps whose ModelServing ownerReference does not match
  the current UID are reset to an empty tracker and rebound to the current UID.

Controller hardening discovered during Kind verification:

- `pkg/model-serving-controller/controller/model_serving_controller.go` now logs
  old-owner UID defensively when a Pod is not owned by the current ModelServing.
  The previous log path indexed `pod.OwnerReferences[0]` after detecting an
  orphan or previous-lifecycle Pod, which could panic during same-name cleanup
  scenarios.

### Unit Tests

From `kthena/`:

```bash
GOCACHE=/Users/vanderchen/workspace/dev/kthena-workspace/kthena/.gocache \
GOPATH=/Users/vanderchen/workspace/dev/kthena-workspace/kthena/.gopath \
go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandlerRefreshesLivePodsForRecoveredServingGroupTracker|TestEvictionHandlerKeepsServingGroupTrackerWhenLivePodsStillContainTriggerUID|TestEvictionHandlerRefreshesLivePodsForRecoveredRoleTracker'

GOCACHE=/Users/vanderchen/workspace/dev/kthena-workspace/kthena/.gocache \
GOPATH=/Users/vanderchen/workspace/dev/kthena-workspace/kthena/.gopath \
go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandlerResetsTrackerFromPreviousSameNamedModelServing|TestEvictionHandlerIgnoresPodsFromPreviousSameNamedModelServing|TestEvictionHandlerAllowsPodFromPreviousSameNamedModelServing'

GOCACHE=/Users/vanderchen/workspace/dev/kthena-workspace/kthena/.gocache \
GOPATH=/Users/vanderchen/workspace/dev/kthena-workspace/kthena/.gopath \
go test ./pkg/model-serving-controller/webhook

export GOCACHE=/Users/vanderchen/workspace/dev/kthena-workspace/kthena/.gocache
export GOPATH=/Users/vanderchen/workspace/dev/kthena-workspace/kthena/.gopath
go test $(go list ./... | grep -v /e2e | grep -v /client-go)
```

Results:

- Targeted webhook regression tests passed.
- Full `pkg/model-serving-controller/webhook` package passed.
- Full `pkg/model-serving-controller/controller` package passed after the
  ownerReference logging guard was added.
- Non-e2e/client-go unit suite passed.

`go test ./...` was also run with the same cache settings. All normal packages
passed, but e2e packages failed during their Helm install setup because the
existing Kind cluster already had a ModelServing CRD managed by `kubectl`:

```text
failed to install CRD crds/workload.serving.volcano.sh_modelservings.yaml:
conflict with "kubectl": .spec.versions
```

This is an environment/cluster ownership conflict, not a unit test failure.

### Kind Verification

Built and deployed the current branch:

```bash
GOOS=linux GOARCH=arm64 go build \
  -o ../local-output/kthena-controller-manager \
  ./cmd/kthena-controller-manager/main.go

docker build -t kthena-controller-manager:dev-007-currentready-fix \
  -f Dockerfile.local \
  --build-arg BINARY_DIR=local-output \
  --build-arg BINARY_NAME=kthena-controller-manager .

kind load docker-image kthena-controller-manager:dev-007-currentready-fix --name kind

helm upgrade --install kthena ./charts/kthena \
  --namespace kthena-system \
  --create-namespace \
  --set workload.controllerManager.image.repository=kthena-controller-manager \
  --set workload.controllerManager.image.tag=dev-007-currentready-fix \
  --set workload.controllerManager.image.pullPolicy=IfNotPresent \
  --set workload.controllerManager.evictionWebhook.enabled=true

kubectl rollout status deployment/kthena-controller-manager \
  -n kthena-system \
  --timeout=120s
```

Verified deployment image:

```text
kthena-controller-manager:dev-007-currentready-fix
```

With all `evict-currentready` Pods Ready and ModelServing `Available=True`,
patched the tracker with an old trigger UID:

```text
triggerPodUID="old-prefill-uid"
```

Then evicted `evict-currentready-2-prefill-0-0` through the eviction subresource.
The request succeeded:

```text
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
```

The tracker moved from stale group 0 to the newly allowed group 2:

```text
entries: '{"ServingGroup/eviction-007-currentready/evict-currentready/evict-currentready-2":{"expiresAt":"2026-06-17T10:10:36.97832626Z","triggerPodUID":"8269d059-a2a8-4297-b522-9e84913ef033","triggerPodName":"evict-currentready-2-prefill-0-0"}}'
```

Controller-manager log after the fix:

```text
10:09:36.978 ... Cleaned eviction tracker entries ... entriesBefore=1 entriesAfter=0
10:09:36.978 ... targetGroup="evict-currentready-2" ... readyGroups=3 ... allowed=true reason="ready groups exceed minAvailable"
10:09:36.978 ... Updated eviction disruption tracker ... entries=1 keys=[ServingGroup/eviction-007-currentready/evict-currentready/evict-currentready-2]
```

### Kind Same-Name Verification

Built and deployed the current branch with the same-name hardening:

```text
kthena-controller-manager:dev-007-same-name-fix-v2
```

Verified deployment:

```text
kthena-controller-manager:dev-007-same-name-fix-v2
--enable-eviction-webhook=true
--eviction-tracker-ttl=60s
```

Current ModelServing UID:

```text
eviction-007-currentready/evict-currentready
uid=f2f3b141-4892-40e2-a289-591f90f18336
```

#### Stale Tracker Without Current Owner

Injected a stale tracker ConfigMap with no current ownerReference and an active
old entry for group 0:

```text
entries: '{"ServingGroup/eviction-007-currentready/evict-currentready/evict-currentready-0":{"expiresAt":"2030-01-01T00:00:00Z","triggerPodUID":"old-same-name-trigger-uid","triggerPodName":"old-same-name-notready"}}'
```

Evicted current Pod `evict-currentready-2-prefill-0-0`. The eviction succeeded:

```text
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
```

Tracker after admission was rebound to the current ModelServing UID and only
contained the newly allowed group 2 entry:

```text
ownerUID: f2f3b141-4892-40e2-a289-591f90f18336
entries: '{"ServingGroup/eviction-007-currentready/evict-currentready/evict-currentready-2":{"expiresAt":"2026-06-17T17:07:29.299955921Z","triggerPodUID":"15833420-d712-4df8-8834-59429a8e348f","triggerPodName":"evict-currentready-2-prefill-0-0"}}'
```

Controller-manager log:

```text
17:06:29.296 ... Resetting stale eviction tracker ConfigMap eviction-007-currentready/kthena-eviction-tracker-evict-currentready because owner does not match current ModelServing uid=f2f3b141-4892-40e2-a289-591f90f18336
17:06:29.299 ... readyGroups=3 observedGroups=3 totalReplicas=3 minAvailable=2 allowed=true reason="ready groups exceed minAvailable"
17:06:29.299 ... trackerEntries=0 trackerKeys=[] allPods=6 disruptionUnit="ServingGroup/eviction-007-currentready/evict-currentready/evict-currentready-2"
```

#### Same-Name Orphan Pod Filtering

Injected an orphan same-name, same-role-id NotReady Pod:

```text
pod: orphan-same-name-notready
ownerReferences: <empty>
group: evict-currentready-0
role: prefill
roleID: prefill-0
ready: False
```

With the orphan Pod present and tracker empty, evicted current Pod
`evict-currentready-0-prefill-0-0`. The eviction succeeded:

```text
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
```

The webhook log proves the orphan Pod was not included in the admission budget:

```text
17:13:02.687 ... targetGroup="evict-currentready-0" targetFound=true targetReady=true readyGroups=3 observedGroups=3 totalReplicas=3 minAvailable=2 allowed=true reason="ready groups exceed minAvailable"
17:13:02.687 ... trackerEntries=0 trackerKeys=[] allPods=6 disruptionUnit="ServingGroup/eviction-007-currentready/evict-currentready/evict-currentready-0"
```

During the first orphan-Pod verification attempt, the model-serving controller
panicked while logging `pod.OwnerReferences[0].UID` for an orphan Pod. The
controller guard described above was added, rebuilt into
`dev-007-same-name-fix-v2`, and redeployed. Re-running the same orphan scenario
then produced warnings instead of a panic:

```text
manageRoleReplicas: pod eviction-007-currentready/orphan-same-name-notready may be left from previous same-named ModelServing eviction-007-currentready/evict-currentready (expected UID=f2f3b141-4892-40e2-a289-591f90f18336, got UID=), re-enqueuing
```

Final Kind state after cleanup and controller restart:

```text
controller-manager image: kthena-controller-manager:dev-007-same-name-fix-v2
controller-manager restartCount: 0
ModelServing availableReplicas: 3
ModelServing Available: True
message: All Serving groups are ready
```
