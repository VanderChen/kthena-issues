# Bug 007: Eviction webhook currentReady recovery is stale

## Status

IP

## Problem

The eviction webhook has a serious correctness issue in the `currentReady`
decision path for ModelServing eviction protection.

Observed problematic scenarios:

1. After a ServingGroup has recovered and all Pods are Ready again,
   `currentReady` may not increase. The webhook can keep treating the recovered
   logical unit as unavailable because of stale informer cache state or stale
   disruption tracker state.
2. After one eviction and an immediate second eviction, `currentReady` may not
   recover in time. This can incorrectly deny evictions that should be allowed
   after recovery, or keep the budget consumed until the tracker TTL expires.

## Impact

The webhook can block valid node drains or rolling maintenance longer than
necessary. In the worst case, the logical eviction budget is tied to cache/tracker
lag instead of the actual recovered readiness of the ServingGroup or Role unit.

## Expected Behavior

When the original disrupted unit has been replaced and the corresponding
ServingGroup or Role instance is fully Ready again, the webhook should count it
as ready for `currentReady` immediately enough for the next eviction decision.
It should not wait for the disruption tracker TTL when live or refreshed state
can prove recovery.

## Notes

This bug is related to the eviction budget work tracked by:

- `issues/features/006-modelserving-eviction-budget-rework-IP`
- `issues/bugs/006-servinggroup-minavailable-full-protection-DONE`

The current implementation branch to use as the bug baseline is:

```text
fix/006-servinggroup-minavailable-full-protection
```

