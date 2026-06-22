# Feature Request: Rework ModelServing Eviction Budget Semantics

## Summary
Revisit the ModelServing eviction webhook design introduced by
`187ea0629eea02435cbe847c624b8bdf2bae3d0e` and fix two design gaps:

1. Role-level protection currently uses one global `minAvailable`, but different
   roles such as `prefill`, `decode`, `controller`, or `worker` need independent
   availability budgets.
2. Concurrent drain events from multiple nodes must be handled atomically under a
   single-active eviction webhook model before informer caches observe previous
   evictions.
3. Operators need an explicit way to disable eviction protection globally because
   a `pods/eviction` admission webhook adds latency to node drain workflows.

## Motivation
The current design protects ServingGroups reasonably well in a single webhook
process, but role-level protection is too coarse for heterogeneous LLM serving
topologies. A single threshold cannot describe xPyD or disaggregated deployments
where roles have different capacities and availability requirements.

The current in-memory disruption tracker also only serializes requests handled by
one process. Short bursts of `pods/eviction` requests from multiple node drains
can still race if the webhook is deployed with multiple replicas, or if requests
are distributed across controller-manager instances.

## Proposed Behavior
- Keep `ServingGroup` protection behavior backward compatible.
- Provide a cluster-level switch to install or skip the eviction webhook.
- For `Role` protection, support role-specific `minAvailable` values.
- Treat role availability at the logical role-instance level, using
  `modelserving.volcano.sh/role-id`, not at raw Pod count level.
- Treat all Pods in the same already-disrupted logical unit as safe to evict, so
  a drain can finish clearing the disrupted ServingGroup or role instance.
- Use an in-memory logical-unit disruption tracker under the single-active
  webhook assumption.
- Ensure admission traffic for eviction protection is served by only one active
  controller-manager instance.

## Requirements
- Preserve compatibility with existing `evictionStrategy.minAvailable`.
- Make eviction protection opt-in at the cluster level and at the ModelServing
  level.
- Add role-specific API without changing existing ServingGroup semantics.
- Validate `roleMinAvailable` keys in the ModelServing validating webhook.
- Expose tracker TTL as a controller-manager initialization parameter with a
  default of 60 seconds.
- Default the cluster-level eviction webhook switch to disabled.
- When eviction webhook is enabled in Helm, deploy controller-manager as one
  replica.
- Cover single-node and multi-node drain races in unit tests.
- Add Kind verification manifests or scripts for concurrent drain scenarios.
- Do not implement until the revised proposal is reviewed and approved.
