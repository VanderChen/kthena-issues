# Bug Description

## Summary

When a node drain evicts a ModelServing Pod that is already not ready, the
eviction webhook can deny the request because that not-ready target has already
reduced `currentReady` to `minAvailable`.

The not-ready target Pod should be evictable because evicting it does not reduce
current availability further.

## Steps to Reproduce

1. Configure a ModelServing eviction strategy with `minAvailable` equal to the
   number of currently ready ServingGroups or role instances.
2. Place one target Pod on the node being drained in a not-ready state.
3. Submit a `pods/eviction` request for that not-ready Pod.

## Expected Behavior

The webhook allows eviction of the target Pod when the target Pod itself is
already not ready.

For Role protection, the same behavior should apply to an already not-ready Pod
inside the target role instance.

## Actual Behavior

The webhook treats the containing ServingGroup or role instance as not ready,
uses the reduced ready count as `currentReady`, and denies the not-ready target
at the `minAvailable` boundary.

Current unit coverage captures this old behavior:

```text
TestEvictionHandlerDeniesUntrackedNotReadyServingGroupAtMinAvailable
```

## Environment Details

- Kthena Version: local workspace
- Component: `kthena-controller-manager` eviction webhook
- Kubernetes Version: not cluster-specific; reproducible in webhook unit tests
- Relevant Logs/Events: denial reason includes current ready count at or below
  `minAvailable`
