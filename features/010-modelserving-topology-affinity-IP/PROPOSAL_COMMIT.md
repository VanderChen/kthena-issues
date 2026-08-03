# Proposal: ModelServing Topology Affinity

## Status

Implemented and verified on branch `feat/010-modelserving-topology-affinity`.
The task remains `IP` until Volcano publishes the topology-affinity API in the
official `volcano.sh/apis` module; the Kthena branch currently uses the matching
commit from `github.com/VanderChen/volcano` as a temporary module replacement.

## Context and Existing Model

The design was checked against:

- Kthena's current `ModelServing`, `ServingGroup`, `Role`, and PodGroup manager;
- Volcano's topology-affinity work on local branch
  `dev/podgroup-antiaffinity`;
- Volcano `PodGroup.spec.topologyAffinity`, including
  `podGroupAntiAffinity`, `subGroupAffinity`, and `subGroupAntiAffinity`.

Kthena already creates scheduling objects with the exact granularity needed by
the Volcano feature:

| ModelServing concept | Generated Volcano concept | Current identity |
| --- | --- | --- |
| one ServingGroup replica | one PodGroup | generated ServingGroup name |
| one Role definition | one SubGroupPolicy | `Role.name` |
| one Role replica | one SubJob | `modelserving.volcano.sh/role-id` |
| Pods in one Role replica | members of that SubJob | entry Pod plus worker Pods |

The existing `appendSubGroupPolicy` function creates one policy per Role and
uses `modelserving.volcano.sh/role-id` in `matchLabelKeys`. Consequently, role
topology rules can refer to stable Role names in ModelServing and translate
directly to SubGroup policy names in PodGroup.

### Role replicas, SubGroupPolicy, and SubJob identity

`SubGroupPolicy`, `MinSubGroups`, and a concrete SubJob have different roles in
the Volcano model:

| Object/field | Meaning in the Kthena conversion |
| --- | --- |
| one `SubGroupPolicy` | one Role definition, such as `prefill` |
| `matchLabelKeys: [modelserving.volcano.sh/role-id]` | partitions matching Pods by Role instance |
| one distinct `role-id` value | one concrete Volcano SubJob/subgroup |
| `subGroupSize` | number of Pods required in one Role instance: entry plus workers |
| `minSubGroups` | minimum number of ready/pipelined Role-instance SubJobs required by gang scheduling |

For example, a `prefill` Role with `replicas: 3` and `workerReplicas: 2`
produces one policy, not three policies:

```yaml
subGroupPolicy:
- name: prefill
  labelSelector:
    matchLabels:
      modelserving.volcano.sh/role: prefill
  matchLabelKeys:
  - modelserving.volcano.sh/role-id
  subGroupSize: 3
  minSubGroups: 3
```

The generated Pods carry `role-id` values `prefill-0`, `prefill-1`, and
`prefill-2`. Volcano's `getSubJobMatchValues` reads those values and
`getSubJobID` creates three distinct SubJobs under the same policy GID. All
entry/worker Pods with `prefill-0` belong to the first SubJob, and so on.

`minSubGroups: 3` does not create or identify those SubJobs. It is only the gang
threshold checked after the Pods have already been partitioned by `role-id`.
If `gangPolicy.minRoleReplicas.prefill` is lower than `Role.replicas`, the
threshold is lower, but all actual Prefill replicas still have distinct SubJobs.

This distinction keeps the topology-affinity conversion small. A Volcano
topology term's `subGroups` list contains **SubGroupPolicy names**, not concrete
SubJob IDs. Therefore Kthena translates:

```yaml
roleAntiAffinity:
  required:
  - roles: [prefill]
    topologyTierName: node
```

to:

```yaml
subGroupAntiAffinity:
  required:
  - subGroups: [prefill]
    topologyTierName: node
```

The Volcano topology-affinity plugin then applies the one-policy term to every
concrete Prefill SubJob and enforces pairwise domain separation. Kthena must not
enumerate `prefill-0`, `prefill-1`, and `prefill-2`, and must not generate one
SubGroupPolicy per Role replica.

## Separation from `networkTopology`

The two APIs solve different placement questions and should remain siblings:

| API | Question answered |
| --- | --- |
| `networkTopology` | How large a topology envelope may one ServingGroup or Role replica occupy? |
| `topologyAffinity` | Must selected groups share or avoid the same topology domain? |

For example, `networkTopology.rolePolicy.highestTierName: node` aggregates all
Pods in one Role replica onto one node-domain HyperNode. A
`topologyAffinity.roleAntiAffinity` term for the same Role at `node` then spreads
different replicas of that Role across different node domains.

## Proposed ModelServing API

Add the following field to `ServingGroup`:

```go
type ServingGroup struct {
    // Existing fields omitted.

    // TopologyAffinity defines topology relationships between ServingGroups
    // and between Role replicas. It requires a scheduler that supports the
    // generated topology-affinity policy.
    // +optional
    TopologyAffinity *TopologyAffinity `json:"topologyAffinity,omitempty"`
}
```

Add ModelServing-native types rather than exposing Volcano PodGroup types:

```go
// TopologyAffinity defines group relationship rules on the HyperNode tree.
type TopologyAffinity struct {
    // ServingGroupAntiAffinity separates ServingGroups belonging to this
    // ModelServing. The controller selects peer PodGroups automatically.
    // +optional
    ServingGroupAntiAffinity *ServingGroupAntiAffinity `json:"servingGroupAntiAffinity,omitempty"`

    // RoleAffinity co-locates selected Role replicas within each ServingGroup.
    // +optional
    RoleAffinity *RoleAffinity `json:"roleAffinity,omitempty"`

    // RoleAntiAffinity spreads or separates selected Role replicas within each
    // ServingGroup.
    // +optional
    RoleAntiAffinity *RoleAntiAffinity `json:"roleAntiAffinity,omitempty"`
}

type ServingGroupAntiAffinity struct {
    // +optional
    Required []ServingGroupAffinityTerm `json:"required,omitempty"`
    // +optional
    Preferred []ServingGroupAffinityTerm `json:"preferred,omitempty"`
}

type RoleAffinity struct {
    // +optional
    Required []RoleAffinityTerm `json:"required,omitempty"`
    // +optional
    Preferred []RoleAffinityTerm `json:"preferred,omitempty"`
}

type RoleAntiAffinity struct {
    // +optional
    Required []RoleAffinityTerm `json:"required,omitempty"`
    // +optional
    Preferred []RoleAffinityTerm `json:"preferred,omitempty"`
}

type ServingGroupAffinityTerm struct {
    // Weight is forbidden for required terms and required for preferred terms.
    // +kubebuilder:validation:Minimum=1
    // +kubebuilder:validation:Maximum=100
    // +optional
    Weight *int32 `json:"weight,omitempty"`

    // Exactly one of TopologyTierName and TopologyTier must be set.
    // TopologyTierName is recommended because it is independent of numeric
    // tier assignments.
    // +kubebuilder:validation:MaxLength=253
    // +optional
    TopologyTierName string `json:"topologyTierName,omitempty"`

    // +kubebuilder:validation:Minimum=0
    // +optional
    TopologyTier *int32 `json:"topologyTier,omitempty"`
}

type RoleAffinityTerm struct {
    // Roles contains names from spec.template.roles.
    // +listType=set
    // +kubebuilder:validation:MinItems=1
    Roles []string `json:"roles"`

    // Weight is forbidden for required terms and required for preferred terms.
    // +kubebuilder:validation:Minimum=1
    // +kubebuilder:validation:Maximum=100
    // +optional
    Weight *int32 `json:"weight,omitempty"`

    // Exactly one of TopologyTierName and TopologyTier must be set.
    // +kubebuilder:validation:MaxLength=253
    // +optional
    TopologyTierName string `json:"topologyTierName,omitempty"`

    // +kubebuilder:validation:Minimum=0
    // +optional
    TopologyTier *int32 `json:"topologyTier,omitempty"`
}
```

The API deliberately does not expose `podGroupSelector`, `namespaceSelector`,
or `subGroups`:

- ServingGroup peers are always the other generated PodGroups of the same
  ModelServing in the same namespace.
- Role names are translated to controller-generated SubGroupPolicy names.
- Cross-ModelServing and cross-namespace selection remain out of scope for the
  first version.

## Term Semantics

All domains are HyperNode domains. `topologyTierName` must equal a
`HyperNode.spec.tierName`; `topologyTier` must equal a HyperNode numeric tier.
The name form is recommended.

### Required and preferred

- Every `required` term is a hard constraint. Multiple required terms are ANDed.
- `required` terms must not set `weight`.
- Every `preferred` term is a soft scoring rule and must set `weight: 1..100`.
- A preferred rule may be violated when resources or hard constraints require
  another placement.

### ServingGroup anti-affinity

Each term compares the current ServingGroup PodGroup with every other PodGroup
generated for the same ModelServing. The current PodGroup is excluded by
Volcano. A hard term requires peer ServingGroups to occupy different domains at
the selected tier.

### Role affinity

`roles` must contain at least two distinct Role names. Every Role replica
(Volcano SubJob) produced by the listed Role policies must share one topology
domain at the selected tier.

For example, `roles: [prefill, decode]` at `rack` means all Prefill and Decode
Role replicas in one ServingGroup are placed in the same rack domain. It does
not pair replicas by ordinal.

### Role anti-affinity

The meaning follows Volcano SubGroup anti-affinity:

- One Role name, such as `roles: [prefill]`: all replicas of that Role are
  pairwise spread across distinct domains at the selected tier.
- Two or more Role names, such as `roles: [prefill, decode]`: replicas from
  different listed Roles cannot share a domain. Replicas of the same Role may
  still share a domain unless a separate one-Role term is added.

Thus spreading Prefill replicas and Decode replicas across nodes requires two
terms: `[prefill]` and `[decode]`.

## Example xPyD Composition

The complete illustrative manifest is in `FEATURE_DESIGN.yaml`. Its relevant
placement fragment is:

```yaml
spec:
  replicas: 3
  schedulerName: volcano
  template:
    networkTopology:
      groupPolicy:
        mode: hard
        highestTierName: communication-domain
      rolePolicy:
        mode: hard
        highestTierName: node
    topologyAffinity:
      servingGroupAntiAffinity:
        required:
        - topologyTierName: communication-domain
      roleAffinity:
        required:
        - roles: [prefill, decode]
          topologyTierName: rack
      roleAntiAffinity:
        required:
        - roles: [prefill]
          topologyTierName: node
        - roles: [decode]
          topologyTierName: node
```

This composition means:

1. One ServingGroup remains inside one communication domain.
2. Different ServingGroups use different communication domains.
3. All Prefill and Decode Role replicas in a ServingGroup share one rack.
4. Every Prefill replica uses a different node domain from other Prefill
   replicas.
5. Every Decode replica uses a different node domain from other Decode
   replicas.
6. A Prefill replica and a Decode replica may share a node because no
   cross-role `[prefill, decode]` anti-affinity term is configured.

This is only an example. The API has no built-in knowledge of P/D roles or tier
names.

## Controller Translation

For ModelServing `default/llama` and generated ServingGroup `llama-0`, the
controller translates fields as follows:

| ModelServing field | PodGroup field | Controller-added data |
| --- | --- | --- |
| `servingGroupAntiAffinity` | `topologyAffinity.podGroupAntiAffinity` | `podGroupSelector.matchLabels[modelserving.volcano.sh/name]=llama` |
| `roleAffinity` | `topologyAffinity.subGroupAffinity` | `roles` renamed to `subGroups` |
| `roleAntiAffinity` | `topologyAffinity.subGroupAntiAffinity` | `roles` renamed to `subGroups` |
| tier and weight fields | same Volcano term fields | pointer weight converted to Volcano scalar weight |

Representative generated PodGroup fragment:

```yaml
metadata:
  name: llama-0
  namespace: default
  labels:
    modelserving.volcano.sh/name: llama
    modelserving.volcano.sh/group-name: llama-0
spec:
  subGroupPolicy:
  - name: prefill
    labelSelector:
      matchLabels:
        modelserving.volcano.sh/name: llama
        modelserving.volcano.sh/role: prefill
    matchLabelKeys:
    - modelserving.volcano.sh/role-id
  - name: decode
    labelSelector:
      matchLabels:
        modelserving.volcano.sh/name: llama
        modelserving.volcano.sh/role: decode
    matchLabelKeys:
    - modelserving.volcano.sh/role-id
  topologyAffinity:
    podGroupAntiAffinity:
      required:
      - podGroupSelector:
          matchLabels:
            modelserving.volcano.sh/name: llama
        topologyTierName: communication-domain
    subGroupAffinity:
      required:
      - subGroups: [prefill, decode]
        topologyTierName: rack
    subGroupAntiAffinity:
      required:
      - subGroups: [prefill]
        topologyTierName: node
      - subGroups: [decode]
        topologyTierName: node
```

## Validation

CRD schema markers should enforce local scalar/list constraints. The
ModelServing validating webhook should enforce cross-field rules and produce
field-specific errors.

Required checks:

1. `schedulerName` must be `volcano` when `topologyAffinity` is set in this
   initial implementation; otherwise the policy would be silently ineffective.
2. At least one non-empty rule block must exist when `topologyAffinity` is set.
3. Every term sets exactly one of `topologyTierName` and `topologyTier`.
4. Required terms have no `weight`.
5. Preferred terms have `weight` in `1..100`.
6. Role names in a term are unique and exist in `spec.template.roles`.
7. Role-affinity terms contain at least two Role names.
8. Role anti-affinity terms contain at least one Role name.
9. For overlapping hard Role affinity and anti-affinity rules expressed with
   numeric tiers, the affinity tier must be equal to or coarser than the
   anti-affinity tier, matching Volcano admission semantics.
10. Named-tier hierarchy conflicts cannot be proven from the ModelServing CRD;
    Volcano resolves and validates known tier names at scheduling time.

One-Role anti-affinity is allowed even when the Role currently has one replica.
It is a harmless no-op and remains valid if that Role later scales out.

## Runtime Capability and Failure Behavior

The current controller detects whether the installed PodGroup CRD exposes
`subGroupPolicy`. Extend this discovery to independently detect
`spec.topologyAffinity`.

Behavior:

- A ModelServing without `topologyAffinity` keeps existing compatibility.
- A ModelServing with ServingGroup rules requires PodGroup
  `spec.topologyAffinity`.
- A ModelServing with Role rules requires both PodGroup
  `spec.topologyAffinity` and `spec.subGroupPolicy`.
- Missing capability returns a clear reconciliation error and Kubernetes Event;
  the controller must not create or update a PodGroup after dropping the rule.
- The implementation must update `volcano.sh/apis` to a commit/release that
  includes these typed fields before code can be compiled.
- The Volcano scheduler must enable both `network-topology-aware` when
  `networkTopology` is used and `group-topology-affinity` when
  `topologyAffinity` is used.

## Node-level Caveat

Volcano topology-affinity compares ancestor HyperNode domains. It does not
compare raw Kubernetes Node hostnames or Kubernetes `topologyKey` labels.

Therefore the example's `topologyTierName: node` requires a leaf HyperNode tier
named `node`, normally with one HyperNode domain per Kubernetes Node. If the
cluster's HyperNode tree has rack HyperNodes directly containing real Nodes,
there is no node tier for this feature to compare. In that topology, node-level
separation must use ordinary Pod anti-affinity/topology spread, or the HyperNode
tree must be extended with a node tier.

## Update Semantics

Topology terms use scheduling-time semantics: changing a ModelServing updates
its generated PodGroups and affects pending or subsequently recreated Pods. It
does not evict already-running Pods merely because their current placement no
longer satisfies a new rule.

Immediate convergence of existing Pods would require an explicit rollout or a
separate placement-migration design and is out of scope for this first version.

## Implementation Summary

1. Added ModelServing-owned topology-affinity types, CRD validation markers,
   generated deep-copy/apply-configuration code, CRD YAML, and API reference.
2. Added webhook validation for scheduler selection, non-empty rules, tier and
   weight constraints, Role references/cardinality, and statically comparable
   hard numeric-tier conflicts. Equal numeric tiers and named-tier hierarchy
   remain aligned with Volcano admission semantics.
3. Added independent PodGroup CRD capability detection for
   `spec.topologyAffinity` and fail-closed reconciliation. Role rules additionally
   require `spec.subGroupPolicy`; failures emit `PodGroupSyncFailed` Events.
4. Added exact ServingGroup-to-PodGroup and Role-to-SubGroup conversions,
   including automatic peer selectors, preferred weights, updates, clearing,
   and PodGroup change detection.
5. Kept one SubGroupPolicy per Role. Role replicas remain distinct SubJobs via
   `modelserving.volcano.sh/role-id`; no per-replica policy or topology term is
   generated.
6. Added user documentation, sidebar navigation, a complete example manifest,
   unit tests, controller Event tests, and runtime capability tests.
7. Added a temporary `replace volcano.sh/apis =>
   github.com/VanderChen/volcano/staging/src/volcano.sh/apis` at commit
   `47e691146727`. Remove it after the official Volcano module publishes the API.

## Verification Plan

### Unit and API tests

- Deep-copy, CRD generation, and generated client checks.
- Valid required/preferred terms and all invalid weight/tier combinations.
- Unknown/duplicate Role references and invalid Role affinity cardinality.
- Exact ModelServing-to-PodGroup conversion for all three rule blocks.
- Automatic peer selector generation.
- Multiple Role replicas still generate one SubGroupPolicy with `role-id` in
  `matchLabelKeys`, correct `subGroupSize`, and correct `minSubGroups`.
- Role topology terms contain Role policy names only and never enumerate Role
  instance IDs.
- Creation, update, and clearing of PodGroup topology affinity.
- Old PodGroup CRD capability detection and fail-closed reconciliation.
- No behavior change when `topologyAffinity` is absent.

### Kind verification

Use a HyperNode tree containing at least:

```text
node -> rack -> communication-domain
```

Verify:

- multiple ServingGroups occupy distinct communication domains;
- Prefill and Decode replicas of each ServingGroup share one rack;
- Prefill replicas occupy distinct node domains;
- Decode replicas occupy distinct node domains;
- insufficient domains keep required rules Pending with useful scheduler logs;
- equivalent preferred rules can fall back and still schedule;
- generated PodGroups contain the expected selectors, SubGroupPolicy entries,
  and translated terms.

Commands, observed Pod-to-Node/HyperNode placement, PodGroup YAML, controller
logs, and scheduler logs must be recorded here after implementation.

## Verification Results

- Scoped unit tests passed:

  ```text
  GOWORK=off go test ./pkg/model-serving-controller/webhook \
    ./pkg/model-serving-controller/podgroupmanager \
    ./pkg/model-serving-controller/controller
  ```

- The mandatory package regression gate passed on the final commit:

  ```text
  GOWORK=off go test $(go list ./... | rg -v '/e2e')
  ```

- Generation and static checks passed:

  ```text
  make gen-check
  make lint
  make vet
  ```

- `make test-docs` passed TypeScript checking and the Docusaurus production
  build. The build reported only the repository's existing SVG-size,
  broken-anchor, and unused-directive warnings.
- `kubectl apply --dry-run=server` accepted
  `examples/model-serving/topology-affinity.yaml`.

### Kind placement verification

Verification used the local four-node arm64 `kind-kind` cluster. Its Volcano
PodGroup CRD exposed both `spec.subGroupPolicy` and `spec.topologyAffinity`, and
the scheduler enabled `network-topology-aware` plus
`group-topology-affinity`. The HyperNode tree contained four `tier1` node
domains, two `tier2` rack/communication domains, and one `tier3` root domain.

The controller was built as Linux/arm64, packaged as
`kthena-controller-manager:dev-010-topology-affinity`, loaded into Kind, and
deployed with Helm. The image ID was:

```text
sha256:7a1655fdf72e7e72133951c7d5625462911ad6cec3bb3cf37515219af34d95dc
```

The main test created two ServingGroups with required PodGroup anti-affinity at
`tier2`, required Prefill/Decode Role affinity at `tier2`, and separate
one-Role anti-affinity terms at `tier1`. Observed placement was:

| ServingGroup | Role replica placement | Allocated tier2 domain |
| --- | --- | --- |
| `topology-affinity-e2e-0` | Prefill and Decode replicas split between `kind-control-plane` and `kind-worker` | `kind-tier2-pair-a` |
| `topology-affinity-e2e-1` | Prefill and Decode replicas split between `kind-worker2` and `kind-worker3` | `kind-tier2-pair-b` |

This confirmed that ServingGroups used different tier2 domains, all Roles of
one ServingGroup remained in one tier2 domain, and same-Role replicas used
different tier1 node domains.

Generated PodGroups contained exactly two SubGroupPolicy entries (`prefill`
and `decode`), each using `role-id` in `matchLabelKeys` and
`minSubGroups: 2`. Their topology terms contained Role policy names only, plus
the controller-generated ModelServing label selector for PodGroup peers.

Removing `/spec/template/topologyAffinity` cleared the field from both
generated PodGroups; reapplying the manifest restored all translated terms.

### Required and preferred capacity behavior

A second test created three ServingGroups but only two eligible tier2 domains.
With required anti-affinity, two PodGroups reached `Running` and the third
remained `Inqueue` with a Pending Pod. Volcano reported:

```text
HyperNode: 0/8 hyperNodes available: tier-4 0/1 (1 podGroupAntiAffinity);
tier3 0/1 (1 podGroupAntiAffinity); tier2 0/2 (2 podGroupAntiAffinity);
tier1 0/4 (4 podGroupAntiAffinity)
```

Changing the same term to preferred with weight 100 allowed all three
PodGroups to reach `Running`, with the third ServingGroup falling back to an
already-used tier2 domain.

The live validating webhook also rejected an unknown Role reference with a
field-specific `Not found: "missing"` error.

All test ModelServings and PodGroups were deleted after verification. The Helm
release and the temporary `kthena-system` namespace were also removed; the
pre-existing Kthena CRDs were preserved.

## Associated Commits

- Proposal commit: `6a2a4c70 docs: add ModelServing topology affinity proposal`
- Implementation commit: `02dff802 feat: add ModelServing topology affinity`
- Kthena branch: `feat/010-modelserving-topology-affinity`
- Implementation worktree:
  `/Users/vanderchen/workspace/dev/kthena-workspace/kthena-topology-affinity`
