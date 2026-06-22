# Bug: ServingGroup eviction protection miscounts multi-role groups

## Summary

When a `ModelServing` has `spec.replicas: 3`, two roles in each ServingGroup, and

```yaml
rolloutStrategy:
  evictionStrategy:
    protectionLevel: ServingGroup
    minAvailable: 2
```

the ServingGroup-level eviction protection can become ineffective. This can
happen even when all Pods are scheduled onto the same node. After creating the
`ModelServing`, record the Pod distribution across nodes because the verification
must show both placement and eviction behavior.

## Expected Behavior

`protectionLevel: ServingGroup` should treat one ServingGroup as available only
when all expected Pods for all roles in that group are present and Ready.

With three ServingGroups and `minAvailable: 2`:

- evicting Pods from one ready ServingGroup may be allowed;
- evicting Pods from a second ready ServingGroup should be denied while only two
  complete ready ServingGroups remain;
- a partial ServingGroup, where one role Pod is missing or deleting, must not be
  counted as available.

## Observed Risk

The current ServingGroup decision path has two suspicious gaps:

- it only verifies that the Pods currently listed for the group are Ready, and
  does not verify that the complete expected Pod set for every role in the
  ServingGroup is still present;
- it allows eviction for a target ServingGroup that is already considered not
  ready, which can bypass the budget if all ServingGroups become partially
  disrupted during a drain.

The bug is not limited to cross-node role spread; same-node placement must also
be reproduced and covered.

## Scope

This bug is in the eviction webhook implementation currently developed on
`feat/006-modelserving-eviction-budget-rework`. The local `main` branch does not
contain `pkg/model-serving-controller/webhook/eviction_handler.go`, so the fix
branch is based on the current eviction rework branch instead of `main`.
