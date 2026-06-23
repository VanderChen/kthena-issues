# Proposal: Allow eviction for already not-ready target Pods

## Branch

- Implementation branch: `fix/011-notready-target-eviction`
- Base branch: `fix/009-role-currentready-recovery`
- Note: local `main` does not yet contain the eviction handler files. The 011
  branch was therefore based on the clean 009 recovery branch that introduced
  this webhook path.

## Verification Performed

Ran the current webhook tests that cover ServingGroup not-ready behavior and Role
budget behavior:

```bash
cd kthena
go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandlerDeniesUntrackedNotReadyServingGroupAtMinAvailable|TestEvictionHandlerRoleProtection'
```

Result:

```text
ok github.com/volcano-sh/kthena/pkg/model-serving-controller/webhook 0.817s
```

This confirms the current code is internally consistent with the old behavior,
but the old behavior conflicts with the new requirement. In particular,
`TestEvictionHandlerDeniesUntrackedNotReadyServingGroupAtMinAvailable` currently
asserts that a not-ready target Pod is denied when ready groups are at
`minAvailable`.

## Root Cause

`checkServingGroupProtection` first computes readiness for the target
ServingGroup:

```text
targetGroupReady = h.isServingGroupReady(...)
readyGroups = count of ready groups
```

When the target Pod is already not ready, the target group is not ready and is
not counted in `readyGroups`. If `readyGroups <= minAvailable`, the current code
denies the target eviction even though evicting this Pod does not reduce
availability further.

`checkRoleProtection` has the same shape at the role instance level:

```text
targetInstanceReady = h.isRoleInstanceReady(...)
readyInstances = count of ready role instances
```

If the target Pod itself is not ready, the role instance has already been removed
from the ready count. Denying the target eviction blocks node drain/recovery
without protecting additional availability.

Important distinction: this should key off the target Pod readiness, not merely
the target ServingGroup/role instance readiness. If a sibling Pod is not ready
but the target Pod is ready, evicting the ready target can reduce availability
further and should still be protected by the existing budget logic.

## Proposed Solution

Update both protection paths:

1. In `checkServingGroupProtection`, after the target group is observed and
   before the existing `!targetGroupReady` denial path, allow eviction when
   `!isPodReady(targetPod)`.
2. In `checkRoleProtection`, after the target role instance is observed and
   before the existing `!targetInstanceReady` denial path, allow eviction when
   `!isPodReady(targetPod)`.
3. Do not record a disruption tracker entry for this allow path. The target Pod
   has already left readiness, so allowing its eviction does not consume a new
   availability unit.
4. Preserve the existing behavior for ready target Pods whose group or role
   instance is not ready because of some other sibling Pod.

## Test Plan

Update/add focused unit tests in
`pkg/model-serving-controller/webhook/eviction_handler_test.go`:

- Change ServingGroup coverage so a not-ready target Pod at `minAvailable` is
  allowed.
- Add a ServingGroup regression where the target Pod is ready but a sibling Pod
  in the same group is not ready; this should still be denied at
  `minAvailable`.
- Add Role coverage where a not-ready target Pod in a role instance is allowed
  even when ready instances are at `roleMinAvailable`.
- Add Role coverage where the target Pod is ready but another Pod in the same
  role instance is not ready; this should still be denied at
  `roleMinAvailable`.

Verification gate after implementation:

```bash
cd kthena
go test ./pkg/model-serving-controller/webhook
go test $(go list ./... | grep -v /e2e)
```

## Implementation Results

Implemented in:

- `pkg/model-serving-controller/webhook/eviction_handler.go`
- `pkg/model-serving-controller/webhook/eviction_handler_test.go`

Behavior changes:

- ServingGroup protection now allows eviction when the target Pod itself is
  already not ready, even if the containing group has already reduced
  `readyGroups` to `minAvailable`.
- Role protection now allows eviction when the target Pod itself is already not
  ready, even if the containing role instance has already reduced
  `readyInstances` to `roleMinAvailable`.
- These allow paths return no disruption unit, so they do not record a new
  tracker entry.
- Ready target Pods remain protected when the group or role instance is not
  ready because of another sibling Pod.

Added/updated tests:

- `TestEvictionHandlerAllowsNotReadyTargetServingGroupAtMinAvailable`
- `TestEvictionHandlerDeniesReadyTargetWhenOtherNodeMakesServingGroupNotReadyAtMinAvailable`
- `TestEvictionHandlerAllowsNotReadyTargetRoleInstanceAtMinAvailable`
- `TestEvictionHandlerDeniesReadyTargetWhenOtherNodeMakesRoleInstanceNotReadyAtMinAvailable`

The deny-side tests explicitly set the ready target Pod on `drain-node` and the
not-ready sibling Pod on `other-node`. This documents that the new allow path is
limited to the target Pod being not ready, and does not ignore unavailable Pods
on other nodes when a ready target Pod would be evicted.

Verification:

```bash
go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandler(AllowsNotReadyTargetServingGroupAtMinAvailable|DeniesReadyTargetInNotReadyServingGroupAtMinAvailable|AllowsNotReadyTargetRoleInstanceAtMinAvailable|DeniesReadyTargetInNotReadyRoleInstanceAtMinAvailable|RoleProtection)$'
```

```text
ok github.com/volcano-sh/kthena/pkg/model-serving-controller/webhook 1.980s
```

After adding explicit node placement coverage:

```bash
go test ./pkg/model-serving-controller/webhook -run 'TestEvictionHandler(AllowsNotReadyTargetServingGroupAtMinAvailable|DeniesReadyTargetWhenOtherNodeMakesServingGroupNotReadyAtMinAvailable|AllowsNotReadyTargetRoleInstanceAtMinAvailable|DeniesReadyTargetWhenOtherNodeMakesRoleInstanceNotReadyAtMinAvailable)$'
```

```text
ok github.com/volcano-sh/kthena/pkg/model-serving-controller/webhook 0.915s
```

```bash
go test ./pkg/model-serving-controller/webhook
```

```text
ok github.com/volcano-sh/kthena/pkg/model-serving-controller/webhook 0.663s
```

The first sandboxed full regression run failed because local port binding and
host Go module cache writes were blocked by the sandbox:

```text
httptest: failed to listen on a port: listen tcp6 [::1]:0: bind: operation not permitted
go: writing stat cache: ... operation not permitted
```

The same non-e2e regression gate passed when rerun with host permissions:

```bash
go test $(go list ./... | grep -v /e2e)
```

```text
ok github.com/volcano-sh/kthena/pkg/model-serving-controller/webhook (cached)
ok github.com/volcano-sh/kthena/pkg/webhook/cert 6.100s
```

Full command exit code: `0`.

### Kind Verification

Per workspace policy, this issue was not left in `DONE` until the fix was
verified in a real Kind cluster.

Environment:

```text
context: kind-kind
node architecture: arm64
controller-manager image: kthena-controller-manager:dev-011-notready-target-eviction
controller-manager args: --enable-eviction-webhook=true, --eviction-tracker-ttl=60s
```

Build and deploy:

```bash
GOOS=linux GOARCH=arm64 go build \
  -o /Users/vanderchen/workspace/dev/kthena-workspace/local-output/kthena-controller-manager \
  ./cmd/kthena-controller-manager/main.go

docker build -t kthena-controller-manager:dev-011-notready-target-eviction \
  -f Dockerfile.local \
  --build-arg BINARY_DIR=local-output \
  --build-arg BINARY_NAME=kthena-controller-manager .

kind load docker-image kthena-controller-manager:dev-011-notready-target-eviction --name kind

helm upgrade --install kthena ./charts/kthena \
  --namespace kthena-system \
  --create-namespace \
  --set workload.controllerManager.image.repository=kthena-controller-manager \
  --set workload.controllerManager.image.tag=dev-011-notready-target-eviction \
  --set workload.controllerManager.image.pullPolicy=IfNotPresent \
  --set workload.controllerManager.evictionWebhook.enabled=true
```

Rollout result:

```text
deployment "kthena-controller-manager" successfully rolled out
image: kthena-controller-manager:dev-011-notready-target-eviction
args: ["--v=2","--enable-eviction-webhook=true","--eviction-tracker-ttl=60s","--cert-secret-name=kthena-controller-manager-webhook-certs","--service-name=kthena-controller-manager-webhook"]
```

Applied verification resources:

```bash
kubectl apply -f issues/bugs/011-notready-target-eviction-IP/reproduce-kind-notready-target.yaml
kubectl wait --for=condition=Ready pod -l modelserving.volcano.sh/name -n eviction-011-notready-target --timeout=180s
```

Readiness was made controllable through an exec readinessProbe. The verification
then removed `/tmp/ready` from selected Pods:

```bash
kubectl exec -n eviction-011-notready-target evict-sg-target-notready-0-prefill-0-0 -- rm /tmp/ready
kubectl exec -n eviction-011-notready-target evict-sg-other-notready-0-decode-0-0 -- rm /tmp/ready
kubectl exec -n eviction-011-notready-target evict-role-target-notready-0-decode-0-0 -- rm /tmp/ready
kubectl exec -n eviction-011-notready-target evict-role-other-notready-0-decode-0-1 -- rm /tmp/ready
```

Observed Pod state before eviction:

```text
evict-sg-target-notready-0-prefill-0-0     Ready=false  node=kind-worker
evict-sg-target-notready-1-prefill-0-0     Ready=true   node=kind-worker
evict-sg-target-notready-2-prefill-0-0     Ready=true   node=kind-worker

evict-sg-other-notready-0-prefill-0-0      Ready=true   node=kind-worker
evict-sg-other-notready-0-decode-0-0       Ready=false  node=kind-worker2
evict-sg-other-notready-1-prefill-0-0      Ready=true   node=kind-worker
evict-sg-other-notready-1-decode-0-0       Ready=true   node=kind-worker2
evict-sg-other-notready-2-prefill-0-0      Ready=true   node=kind-worker
evict-sg-other-notready-2-decode-0-0       Ready=true   node=kind-worker2

evict-role-target-notready-0-decode-0-0    Ready=false  node=kind-worker   roleID=decode-0
evict-role-target-notready-0-decode-0-1    Ready=true   node=kind-worker2  roleID=decode-0
evict-role-target-notready-0-decode-1-*    Ready=true   nodes=kind-worker/kind-worker2
evict-role-target-notready-0-decode-2-*    Ready=true   nodes=kind-worker/kind-worker2

evict-role-other-notready-0-decode-0-0     Ready=true   node=kind-worker   roleID=decode-0
evict-role-other-notready-0-decode-0-1     Ready=false  node=kind-worker2  roleID=decode-0
evict-role-other-notready-0-decode-1-*     Ready=true   nodes=kind-worker/kind-worker2
evict-role-other-notready-0-decode-2-*     Ready=true   nodes=kind-worker/kind-worker2
```

ServingGroup target-not-ready allow:

```bash
kubectl create --raw \
  /api/v1/namespaces/eviction-011-notready-target/pods/evict-sg-target-notready-0-prefill-0-0/eviction \
  -f issues/bugs/011-notready-target-eviction-IP/evict-sg-target-notready.json
```

Result:

```text
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
```

ServingGroup ready-target deny when another node has a not-ready sibling:

```bash
kubectl create --raw \
  /api/v1/namespaces/eviction-011-notready-target/pods/evict-sg-other-notready-0-prefill-0-0/eviction \
  -f issues/bugs/011-notready-target-eviction-IP/evict-sg-other-ready-target.json
```

Result:

```text
Error from server: admission webhook "eviction.modelserving.volcano.sh" denied the request: Eviction denied: protected by ModelServing evict-sg-other-notready. Target group evict-sg-other-notready-0 is not ready and not tracked; current ready groups (2) <= minAvailable (2).
```

Role target-not-ready allow:

```bash
kubectl create --raw \
  /api/v1/namespaces/eviction-011-notready-target/pods/evict-role-target-notready-0-decode-0-0/eviction \
  -f issues/bugs/011-notready-target-eviction-IP/evict-role-target-notready.json
```

Result:

```text
{"kind":"Status","apiVersion":"v1","metadata":{},"status":"Success","code":201}
```

Role ready-target deny when another node has a not-ready same-roleID sibling:

```bash
kubectl create --raw \
  /api/v1/namespaces/eviction-011-notready-target/pods/evict-role-other-notready-0-decode-0-0/eviction \
  -f issues/bugs/011-notready-target-eviction-IP/evict-role-other-ready-target.json
```

Result:

```text
Error from server: admission webhook "eviction.modelserving.volcano.sh" denied the request: Eviction denied: protected by ModelServing evict-role-other-notready. Target role instance evict-role-other-notready-0/decode/decode-0 is not ready and not tracked; ready instances (2) <= minAvailable (2).
```

Tracker state after the four admission decisions:

```text
kthena-eviction-tracker-evict-sg-target-notready: entries='{}'
kthena-eviction-tracker-evict-sg-other-notready: entries='{}'
kthena-eviction-tracker-evict-role-target-notready: entries='{}'
kthena-eviction-tracker-evict-role-other-notready: entries='{}'
```

Controller-manager decision logs:

```text
ServingGroup ... evict-sg-target-notready ... targetReady=false readyGroups=2 minAvailable=2 allowed=true reason="target pod is already not ready"
Eviction tracker decision ... evict-sg-target-notready ... allowed=true trackerEntries=0 trackerKeys=[] disruptionUnit=""

ServingGroup ... evict-sg-other-notready ... node="kind-worker" targetReady=false readyGroups=2 minAvailable=2 allowed=false reason="... Target group evict-sg-other-notready-0 is not ready and not tracked ..."

Role ... evict-role-target-notready ... targetRoleID="decode-0" targetReady=false readyInstances=2 minAvailable=2 allowed=true reason="target pod is already not ready"
Eviction tracker decision ... evict-role-target-notready ... allowed=true trackerEntries=0 trackerKeys=[] disruptionUnit=""

Role ... evict-role-other-notready ... node="kind-worker" targetRoleID="decode-0" targetReady=false readyInstances=2 minAvailable=2 allowed=false reason="... Target role instance evict-role-other-notready-0/decode/decode-0 is not ready and not tracked ..."
```

## Associated Commits

- Commit ID: pending
- Branch: `fix/011-notready-target-eviction`
