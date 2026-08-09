# Feature 011: ModelServing Headless Service Plugin

## Status

DONE — implemented and verified with the existing unified `HookRequest` and
`Plugin` interface for all lifecycle hooks.

The earlier `spec.enableHeadlessService` design and implementation commit
`ab2cd1548238bf424ff379676d279fc97a3d9638` were superseded and dropped from
the final feature branch history.

## Summary

Headless Service management must not be a dedicated `ModelServingSpec` feature.
It must be an optional built-in ModelServing plugin instead. A ModelServing that
does not select the plugin creates no Headless Services by default.

```yaml
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: ModelServing
metadata:
  name: example
spec:
  plugins:
    - name: headless-service
      type: BuiltIn
  # Remaining fields omitted.
```

No `spec.enableHeadlessService` field is added or retained.

## Motivation

Most ModelServing workloads do not require per-entry-Pod DNS, while the current
controller creates one Headless Service for every active Role replica that has
a `workerTemplate`. Those Services add API objects, watch events, reconciliation
work, and API server/storage load.

Service management is optional integration behavior rather than part of the
core ServingGroup state machine. Treating a Service as proof that a
ServingGroup or Role still exists also couples deletion progress to an optional
resource and prevents Service implementations from evolving independently.

## Required Behavior

- Add a built-in plugin named `headless-service`.
- The plugin is enabled only by an entry in `spec.plugins`; absent means no
  generated Headless Services.
- Remove `enableHeadlessService` from `ModelServingSpec` and all generated
  artifacts, examples, documentation, converters, and tests.
- Preserve the existing generated Service name, owner reference, labels,
  selector, `clusterIP: None`, and `publishNotReadyAddresses` behavior while the
  plugin is enabled.
- Recreate an enabled plugin-owned Service after accidental deletion.
- Delete plugin-owned Services when their corresponding Role is deleted,
  including Role scale-down, rollout replacement, and ServingGroup deletion.
- Never delete user-managed Services or Services owned by another
  ModelServing UID.
- Services must not participate in `isServingGroupDeleted` or `isRoleDeleted`.
  Core deletion completes based on core workload resources only.
- Reuse the existing `OnPodCreate` hook for initial Service creation, extend the
  existing `HookRequest` with Role lifecycle context, and add `OnRoleSync` and
  `OnRoleDelete` directly to the existing `Plugin` interface. Do not introduce
  separate Role request/capability interfaces or a ModelServing-wide reconcile
  hook.
- Service lifecycle failures are returned from the plugin hook so the normal
  ModelServing workqueue retry policy applies.
- Adding or removing the plugin must not roll or restart Pods. Removing the
  plugin does not immediately delete existing Services; they are cleaned only
  when their corresponding Roles are deleted.

## Compatibility

ModelBooster and LeaderWorkerSet conversions that require stable entry DNS must
add the `headless-service` plugin to the generated ModelServing. Multi-node
examples that consume `ENTRY_ADDRESS` must also select the plugin explicitly.

Services created by the superseded implementation do not have the new plugin
identity label. The plugin cleanup path must recognize those legacy Services
using the existing Headless Service shape plus the current ModelServing owner
UID so that Role deletion can clean them safely.

## Non-goals

- Adding Service fields directly to `ModelServingSpec`.
- Custom Service names, ports, selectors, or DNS policy in the first version.
- Making Services part of ServingGroup/Role existence or readiness.
- Remote/Webhook plugin execution.
- Managing Services not controlled by the same ModelServing UID.
