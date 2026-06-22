# Bug: ServingGroup minAvailable equal to replicas still allows eviction

## Summary

When a `ModelServing` has three ServingGroups, two roles per ServingGroup, and:

```yaml
rolloutStrategy:
  evictionStrategy:
    protectionLevel: ServingGroup
    minAvailable: 3
```

the eviction protection should deny every eviction while all three complete
ServingGroups are the only available groups. In practice, at least one Pod can
still be evicted.

## Steps to Reproduce

1. Enable the `pods/eviction` webhook for `kthena-controller-manager`.
2. Apply `reproduce-multirole-servinggroup-minavailable3.yaml`.
3. Wait until all six Pods are Ready:
   - three ServingGroups;
   - two roles per ServingGroup, `prefill` and `decode`;
   - one Pod per role.
4. Trigger a Pod eviction or drain the node that hosts the Pods.

## Expected Behavior

The first eviction request should be denied. With three ServingGroups and
`minAvailable: 3`, evicting any Pod would make its ServingGroup incomplete, so
Ready ServingGroup count would drop from 3 to 2.

## Actual Behavior

An eviction can be admitted even though it should reduce Ready ServingGroups
below the configured minimum.

## Environment Details

- Kthena branch: `fix/006-servinggroup-minavailable-full-protection`
- Relevant code path: `pkg/model-serving-controller/webhook/eviction_handler.go`
- Related prior bug: `issues/bugs/005-servinggroup-eviction-protection-DONE`
