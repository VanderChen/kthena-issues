# Feature Request

## Summary
Add developer-facing documentation for the current `ModelServing` controller
reconcile sequence.

The document should explain how the controller turns a `ModelServing` spec into
ServingGroups, Roles, Pods, Services, PodGroups, ControllerRevisions, and status
updates. It should cover the main reconcile flow and key behavior such as
rolling update, partition protection, scale up/down, recovery after pod failure,
role-level update, deletion ordering, and status calculation.

## Motivation
The `ModelServing` controller contains a large amount of lifecycle logic spread
across the controller, datastore, utilities, PodGroup manager, plugins, and API
types. Developers who need to modify this component currently have to infer the
runtime sequence from code and tests.

A code-oriented walkthrough will reduce onboarding cost and make future changes
to rolling update, recovery policy, autoscaling interactions, and resource
cleanup safer.

## Proposed Behavior
Create a documentation page for developers that describes:

- The controller's informer and workqueue entry points.
- The exact `syncModelServing` execution order.
- How in-memory datastore state is built and used.
- How ServingGroup and Role replicas are created, scaled, deleted, and recovered.
- How `ServingGroupRollingUpdate` and `RoleRollingUpdate` differ.
- How `maxUnavailable` and `partition` affect update and scale-down behavior.
- How `ControllerRevision`, `CurrentRevision`, and `UpdateRevision` preserve
  rollout state.
- How the plugin chain participates in pod creation and readiness handling.
- How Pod, Service, and PodGroup delete/update events feed back into reconcile.
- How final `ModelServing.status` fields and conditions are computed.
- Which code files and tests are the best starting points for future changes.

## Use Cases
- A new contributor needs to understand the reconcile path before changing
  rolling update behavior.
- A maintainer needs to evaluate whether a bug fix affects ServingGroup,
  Role-level update, or status calculation.
- A developer needs to map a runtime symptom, such as stuck `Progressing` or
  unexpected rollout deletion, back to the code path that owns it.

## Requirements
- Keep the document implementation-focused rather than user-facing API reference.
- Include code path references for each major phase.
- Explain the normal path and the important asynchronous feedback loops.
- Include at least one high-level sequence diagram or ordered flow.
- Cover both `ServingGroupRollingUpdate` and `RoleRollingUpdate`.
- Cover partition-protected behavior and why `ControllerRevision` matters.
- Cover deletion-cost based scale-down ordering.
- Cover plugin hook intervention points, hook request fields, and the current
  built-in plugin flow.
- Do not change controller behavior as part of this task.
