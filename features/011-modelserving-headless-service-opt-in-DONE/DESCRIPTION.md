# Feature 011: Opt-in ModelServing Headless Services

## Status

DONE — implemented, regression-tested, and verified in the local Kind cluster.

## Summary

Change ModelServing-managed Headless Services from implicit creation to an
explicit opt-in behavior.

Add `spec.enableHeadlessService`. The controller creates the existing
per-Role-replica Headless Services only when this field is explicitly set to
`true`. Omitting the field, or setting it to `false`, disables them.

```yaml
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: ModelServing
metadata:
  name: example
spec:
  enableHeadlessService: true
  # Remaining fields omitted.
```

## Motivation

The controller currently creates one Headless Service for every active Role
replica that has a `workerTemplate`. Most ModelServing workloads do not consume
the resulting per-Pod DNS names, but every Service still adds API objects,
watch events, reconciliation work, and API server/storage load.

The Service count grows with the workload shape:

```text
ModelServing replicas × sum(Role replicas with workerTemplate)
```

Headless Services should therefore be created only for workloads that require
the entry/worker DNS behavior.

## Proposed Behavior

| `spec.enableHeadlessService` | Desired Headless Services |
| --- | --- |
| omitted | none |
| `false` | none |
| `true` | one per active Role replica with `workerTemplate`, preserving current naming, labels, owner references, selector, and DNS behavior |

State transitions are reconciled as follows:

- `false`/omitted to `true`: create all required Headless Services without
  restarting Pods.
- `true` to `false`: delete Headless Services owned by that ModelServing without
  restarting Pods.
- deletion of an enabled Headless Service: recreate it through the existing
  Service delete event/reconcile path.
- deletion of a disabled Headless Service: do not recreate it.

## Compatibility and Upgrade Impact

This is an intentional default behavior change. Existing ModelServing objects
do not contain the new field, so after upgrading the controller their existing
controller-owned Headless Services will be removed.

Any workload that relies on `ENTRY_ADDRESS`, the Service name matching the entry
Pod name, or per-Pod DNS through the generated Headless Service must add:

```yaml
spec:
  enableHeadlessService: true
```

before or as part of the controller upgrade.

## Requirements

- Add `enableHeadlessService` to `ModelServingSpec` as an optional boolean.
- Do not use API defaulting to turn the field on; omitted must remain disabled.
- Do not create or recreate Headless Services unless the field is `true`.
- When disabled, remove only Headless Services owned by the same ModelServing
  UID; do not delete user-managed Services or Services owned by another
  ModelServing instance.
- Preserve current Headless Service behavior when enabled, including naming,
  labels, selectors, owner references, and `publishNotReadyAddresses`.
- Enabling or disabling the field must not trigger a ServingGroup/Role rollout
  or Pod restart.
- Regenerate the CRD, generated clients/apply configurations, DeepCopy code, and
  API reference documentation through the repository generation workflow.
- Cover default-disabled, explicit-disabled, enabled, cleanup, and recreation
  behavior with tests and real Kind verification.

## Non-goals

- Per-Role or per-Role-replica opt-in controls.
- Customizing generated Service names, selectors, ports, or DNS behavior.
- Changing the injected `ENTRY_ADDRESS`, Pod `hostname`, or Pod `subdomain`
  contract.
- Removing or redesigning the controller's shared Service informer.
