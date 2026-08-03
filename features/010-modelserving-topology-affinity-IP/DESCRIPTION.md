# Feature Request: ModelServing Topology Affinity

## Summary

Add a ModelServing-native topology-affinity API that translates to Volcano's
PodGroup/SubGroup topology-affinity API:

- ServingGroup anti-affinity maps to PodGroup anti-affinity.
- Role affinity maps to SubGroup affinity.
- Role anti-affinity maps to SubGroup anti-affinity.

The ModelServing API uses ServingGroup and Role terminology. Users do not need
to know generated PodGroup names, SubGroupPolicy names, or controller-owned
labels.

## Motivation

`spec.template.networkTopology` currently expresses the maximum topology
envelope for a ServingGroup and its role instances. It cannot express topology
relationships between ServingGroups or selected roles.

Serving workloads also need placement relationships such as:

- isolate ServingGroup replicas across failure or communication domains;
- co-locate selected roles in one rack;
- spread replicas of the same role across nodes or other topology domains;
- express these constraints as either required rules or weighted preferences.

## Proposed Behavior

Add `spec.template.topologyAffinity` with three optional rule blocks:

- `servingGroupAntiAffinity`
- `roleAffinity`
- `roleAntiAffinity`

Each block supports `required` and `preferred` terms. A term selects a HyperNode
tier by name or number. Role terms additionally select role names from
`spec.template.roles`.

The controller translates each generated ServingGroup PodGroup as follows:

- `servingGroupAntiAffinity` becomes `podGroupAntiAffinity` with a
  controller-generated selector for peer PodGroups owned by the same
  ModelServing.
- `roleAffinity` becomes `subGroupAffinity`.
- `roleAntiAffinity` becomes `subGroupAntiAffinity`.

## Use Cases

An illustrative xPyD deployment can combine:

- ServingGroups required on different communication domains;
- Prefill and Decode roles required in the same rack;
- Prefill role replicas required on different nodes;
- Decode role replicas required on different nodes.

This is an example composition rather than a special-purpose preset. Users can
refer to any HyperNode tier and any Role names.

## Requirements

- Keep scheduler-specific PodGroup selectors and SubGroup names out of the
  user-facing ModelServing API.
- Preserve Volcano required/preferred and weight semantics.
- Validate role references, duplicate roles, tier selection, and weights before
  generating PodGroups.
- Never silently drop configured topology-affinity rules when the installed
  Volcano PodGroup CRD lacks the required fields.
- Retain the existing `networkTopology` API for aggregation/envelope policies;
  topology affinity supplements rather than replaces it.
- Document that terms compare HyperNode domains, not Kubernetes topology labels
  or raw Node names.

## Non-goals

- Cross-ModelServing affinity or anti-affinity.
- Cross-namespace matching.
- Cross-PodGroup affinity; the Volcano dependency currently supports
  cross-PodGroup anti-affinity only.
- Automatic creation of HyperNode resources or topology tiers.
- Retroactive eviction of already-running Pods after an affinity policy update.
