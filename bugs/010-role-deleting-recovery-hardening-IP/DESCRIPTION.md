# RoleDeleting recovery can stall after pod eviction

## Problem

Occasionally, after a ModelServing Pod is evicted or deleted, one Pod in a role
is not recreated. A recent production-like case showed
`my-model-serving-test5-0-prefill-1-1` missing while
`my-model-serving-test5-0-prefill-1-0` remained Running.

Controller logs from the elected leader showed the controller noticed the role
was missing Pods and then almost immediately moved the same role into
`RoleDeleting`:

```text
manageRoleReplicas: role prefill/prefill-1 in ServingGroup my-model-serving-test5-0 is missing pods (1/2), recreating
Role prefill/prefill-1 in ServingGroup my-model-serving-test5-0 is now Deleting
```

Other logs showed child delete events being ignored because the ModelServing was
not found in the ModelServing informer cache at that moment:

```text
ModelServing of deleted pod: my-model-serving-test5-0-prefill-1-1 not found, might be already deleted
```

## Scope

Harden the ModelServing controller recovery path for RoleRecreate and
RoleDeleting convergence. The fix should avoid broad live API scans and should
only use live API fallbacks on narrow exceptional paths.

## Notes

- Leader election was confirmed enabled and working for the controller path.
- The eviction tracker ConfigMap in the observed case referenced a different
  ServingGroup, so it is not the direct cause of the missing Pod.
- The likely root cause is interaction between informer cache lag, child delete
  event handling, and a RoleDeleting state that relies on informer index
  convergence.
