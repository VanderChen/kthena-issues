# Proposal: Verify and harden Role currentReady recovery

## Branch

- Current workspace branch: `fix/009-role-currentready-recovery`
- Baseline branch: `fix/007-eviction-currentready-recovery`

## Initial Analysis

The current eviction webhook performs recovered disruption cleanup before
branching into ServingGroup or Role protection:

```text
cleanupDisruptionEntries(entries)
allPods = h.cleanupRecoveredDisruptionEntries(ctx, ms, entries, allPods, targetPod)
if strategy.ProtectionLevel == Role {
    checkRoleProtection(...)
} else {
    checkServingGroupProtection(...)
}
```

Because tracker keys are parsed back into `disruptionUnit`, the existing cleanup
path is intended to support both:

```text
ServingGroup/<namespace>/<modelServing>/<group>
Role/<namespace>/<modelServing>/<group>/<role>/<roleID>
```

There is already unit coverage:

```text
TestEvictionHandlerRefreshesLivePodsForRecoveredRoleTracker
```

The missing part is a Role-specific Kind verification that proves the current
webhook image handles a stale Role tracker entry in a real cluster.

## Verification Plan

Use a dedicated Kind workload:

```text
namespace: eviction-009-role-currentready
ModelServing: evict-role-currentready
ServingGroups: 1
Role: decode
Role replicas: 3
protectionLevel: Role
roleMinAvailable.decode: 2
```

Scenario:

1. Deploy the workload and wait for all three decode role instances to be Ready.
2. Evict `decode-0` once to let the webhook create a tracker ConfigMap with the
   current ModelServing ownerReference.
3. Wait for `decode-0` to recover.
4. Patch only `data.entries` to a stale Role entry for `decode-0` with an old
   `triggerPodUID`.
5. Evict `decode-1`.

Expected:

- The stale `decode-0` Role entry is cleaned before `checkRoleProtection`.
- The second eviction is allowed.
- Logs show Role state with `readyInstances=3`, `allowed=true`, and the tracker
  moves from `decode-0` to `decode-1`.

## Implementation Notes

If Kind verification fails, fix the Role cleanup path and add/adjust unit tests.
If Kind verification passes, no additional implementation change is expected;
this bug records Role-specific proof that the shared cleanup path covers Role
protection.

## Verification Results

### Kind Environment

```text
context: kind-kind
node architecture: arm64
controller-manager image: kthena-controller-manager:dev-007-same-name-fix-v2
controller-manager args: --enable-eviction-webhook=true, --eviction-tracker-ttl=60s
```

Applied:

```bash
kubectl apply -f issues/bugs/009-role-currentready-recovery-IP/reproduce-kind-role-currentready.yaml
```

Initial workload state:

```text
ModelServing UID: 99b6cc0c-8066-4542-ac32-8432ad2fbacf
availableReplicas: 1
Available: True
message: All Serving groups are ready
```

Initial Pods:

```text
evict-role-currentready-0-decode-0-0   uid=66e967e5-6c4a-4428-9fa1-765ef13cc47a   roleID=decode-0   Ready=True
evict-role-currentready-0-decode-1-0   uid=d9f187bf-1af7-4cbc-a270-3b19b3478812   roleID=decode-1   Ready=True
evict-role-currentready-0-decode-2-0   uid=7d11fcd8-27c2-4253-9716-840387a0eae8   roleID=decode-2   Ready=True
```

### Baseline Role Eviction

Evicted `decode-0` once to create a tracker ConfigMap owned by the current
ModelServing:

```bash
kubectl create --raw \
  /api/v1/namespaces/eviction-009-role-currentready/pods/evict-role-currentready-0-decode-0-0/eviction \
  -f issues/bugs/009-role-currentready-recovery-IP/evict-decode-0.json
```

Result:

```text
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
```

The controller recreated a new role instance as `decode-3`, so the recovered
observed role IDs became:

```text
decode-1, decode-2, decode-3
```

This means a stale `decode-0` tracker would no longer affect current observed
Role instances. To specifically validate Role stale cleanup, the tracker was
patched to target existing role instance `decode-1` with an old trigger UID.

### Stale Role Tracker Verification

Patched only `data.entries`, preserving the current ownerReference:

```bash
kubectl patch cm kthena-eviction-tracker-evict-role-currentready \
  -n eviction-009-role-currentready \
  --type=json \
  --patch-file issues/bugs/009-role-currentready-recovery-IP/stale-role-tracker-patch.json
```

Patched tracker:

```text
ownerUID: 99b6cc0c-8066-4542-ac32-8432ad2fbacf
entries: '{"Role/eviction-009-role-currentready/evict-role-currentready/evict-role-currentready-0/decode/decode-1":{"expiresAt":"2030-01-01T00:00:00Z","triggerPodUID":"old-role-trigger-uid","triggerPodName":"old-decode-1"}}'
```

Then evicted current `decode-2`:

```bash
kubectl create --raw \
  /api/v1/namespaces/eviction-009-role-currentready/pods/evict-role-currentready-0-decode-2-0/eviction \
  -f issues/bugs/009-role-currentready-recovery-IP/evict-decode-2.json
```

Result:

```text
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
```

Tracker after admission moved from stale `decode-1` to newly allowed `decode-2`:

```text
ownerUID: 99b6cc0c-8066-4542-ac32-8432ad2fbacf
entries: '{"Role/eviction-009-role-currentready/evict-role-currentready/evict-role-currentready-0/decode/decode-2":{"expiresAt":"2026-06-22T12:35:16.91992284Z","triggerPodUID":"7d11fcd8-27c2-4253-9716-840387a0eae8","triggerPodName":"evict-role-currentready-0-decode-2-0"}}'
```

Controller-manager log:

```text
12:34:16.919 ... Cleaned eviction tracker entries ... entriesBefore=1 entriesAfter=0
12:34:16.919 ... Role eviction state ... targetRole="decode" targetRoleID="decode-2" targetFound=true targetReady=true readyInstances=3 observedInstances=3 totalInstances=3 minAvailable=2 allowed=true reason="ready role instances exceed minAvailable" roleStates=[evict-role-currentready-0/decode-1(pods=1,ready=true,tracked=false) evict-role-currentready-0/decode-2(pods=1,ready=true,tracked=false) evict-role-currentready-0/decode-3(pods=1,ready=true,tracked=false)]
12:34:16.919 ... trackerEntries=0 trackerKeys=[] allPods=3 disruptionUnit="Role/eviction-009-role-currentready/evict-role-currentready/evict-role-currentready-0/decode/decode-2"
12:34:16.922 ... Updated eviction disruption tracker ... entries=1 keys=[Role/eviction-009-role-currentready/evict-role-currentready/evict-role-currentready-0/decode/decode-2]
```

Final workload state after recovery:

```text
availableReplicas: 1
Available: True
message: All Serving groups are ready
```

### Additional Reported Cache-Incomplete Role Reproduction

The user later provided a production-like workload:

```text
ModelServing: default/my-model-serving-test5
ServingGroups: 2
roles:
  prefill replicas=2 workerReplicas=1
  decode replicas=3 workerReplicas=2
protectionLevel: Role
roleMinAvailable:
  decode: 1
  prefill: 1
```

The reported logs showed the Role decision undercounting decode instances:

```text
pod=default/my-model-serving-test5-0-decode-1-0 targetRoleID="decode-1"
readyInstances=1 observedInstances=1 totalInstances=3 minAvailable=1 allowed=false
allPods=1

pod=default/my-model-serving-test5-0-decode-2-2
Pod ... was not found in lister but was found by live API GET
readyInstances=1 observedInstances=1 totalInstances=3 minAvailable=1 allowed=false
allPods=1
```

This proves the Role path can make a decision from an incomplete informer
observation: the target Pod is found, but peer Role instances are absent from the
cached list, so `observedInstances` stays at 1 while `totalInstances` is 3.

### Implementation Update

The eviction handler now refreshes Pods from the live API before budget
calculation when the cached observation is below the expected count:

- ServingGroup protection refreshes when observed groups are fewer than
  `spec.replicas`.
- Role protection refreshes when observed role IDs in the target ServingGroup
  and target Role are fewer than the role's `replicas`.
- The target Pod is still included after live refresh so admission remains
  conservative when the target was fetched by live GET.
- Pod ownership filtering remains strict: Pods must carry the current
  ModelServing ownerReference to be counted. This avoids counting Pods from
  deleted/recreated same-name ModelServings or manually labeled Pods.

### Updated Unit Tests

Role-specific regression test:

```bash
GOCACHE=/Users/vanderchen/workspace/dev/kthena-workspace/.gocache \
GOPATH=/Users/vanderchen/workspace/dev/kthena-workspace/.gopath \
go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandlerRefreshesLivePodsWhenRoleCacheObservationIncomplete|TestEvictionHandlerRefreshesLivePodsForRecoveredRoleTracker'
```

Result:

```text
ok   github.com/volcano-sh/kthena/pkg/model-serving-controller/webhook
```

Full webhook package:

```bash
GOCACHE=/Users/vanderchen/workspace/dev/kthena-workspace/.gocache \
GOPATH=/Users/vanderchen/workspace/dev/kthena-workspace/.gopath \
go test ./pkg/model-serving-controller/webhook
```

Result:

```text
ok   github.com/volcano-sh/kthena/pkg/model-serving-controller/webhook
```

The first sandboxed run with workspace-level GOPATH failed because dependencies
needed to be resolved from `goproxy.cn`; rerunning with network approval passed.

### Updated Kind Verification

Before verification, all existing ModelServings in all namespaces were deleted:

```bash
kubectl delete modelservings.workload.serving.volcano.sh --all --all-namespaces --ignore-not-found=true
```

The cluster was confirmed clean:

```text
kubectl get modelservings.workload.serving.volcano.sh -A
No resources found

kubectl get pods -A -l modelserving.volcano.sh/name
No resources found
```

Built and deployed:

```text
controller-manager image: kthena-controller-manager:dev-009-role-live-refresh
enable-eviction-webhook: true
```

The webhook configuration included pods/eviction:

```text
eviction.modelserving.volcano.sh -> ["pods/eviction"]
```

Applied Role verification workload:

```bash
kubectl apply -f issues/bugs/009-role-currentready-recovery-IP/reproduce-kind-role-cache-incomplete.yaml
```

The verification uses one ModelServing and three manually created decode Pods.
Only the target Pod is labeled for the ModelServing at first. After the target is
Ready, the two peer Pods are labeled and the target is immediately evicted with:

```bash
kubectl create --raw \
  /api/v1/namespaces/eviction-009-role-cache-incomplete/pods/role-cache-incomplete-0-decode-1-0/eviction \
  -f issues/bugs/009-role-currentready-recovery-IP/evict-role-cache-incomplete-decode-1.json
```

Result:

```text
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
```

Controller-manager log:

```text
Role eviction state modelServing=eviction-009-role-cache-incomplete/role-cache-incomplete pod=eviction-009-role-cache-incomplete/role-cache-incomplete-0-decode-1-0 targetRole="decode" targetRoleID="decode-1" targetFound=true targetReady=true readyInstances=3 observedInstances=3 totalInstances=3 minAvailable=1 allowed=true reason="ready role instances exceed minAvailable" roleStates=[role-cache-incomplete-0/decode-0(pods=1,ready=true,tracked=false) role-cache-incomplete-0/decode-1(pods=1,ready=true,tracked=false) role-cache-incomplete-0/decode-2(pods=1,ready=true,tracked=false)]
Eviction tracker decision ... allPods=3 disruptionUnit="Role/eviction-009-role-cache-incomplete/role-cache-incomplete/role-cache-incomplete-0/decode/decode-1"
Updated eviction disruption tracker ... entries=1 keys=[Role/eviction-009-role-cache-incomplete/role-cache-incomplete/role-cache-incomplete-0/decode/decode-1]
```

In this Kind run, the informer observed the two newly labeled peer Pods before
the eviction admission decision, so the live-refresh log branch did not fire.
The deterministic cache-lag condition (`lister` has only the target while live
API has all three Role instances) is covered by
`TestEvictionHandlerRefreshesLivePodsWhenRoleCacheObservationIncomplete`.

## Conclusion

Role granularity required an additional fix beyond stale tracker cleanup. The
webhook now refreshes live Pods when the cache observes fewer Role instances than
the ModelServing spec requires, while keeping Pod ownership filtering strict on
the current ModelServing ownerReference. Unit tests and Kind verification cover
the reported `readyInstances=1 observedInstances=1 totalInstances=3` failure
mode.
