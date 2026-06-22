# Feature: ModelServing Eviction Webhook (ServingGroup Rolling Protection)

## Background
In production environments, node migrations or OS upgrades trigger node evictions (`kubectl drain`). 
Native Kubernetes `PodDisruptionBudget` (PDB) operates purely on Pod counts and is unaware of the logical boundaries of Kthena's `ServingGroup`s. Evicting multiple pods across different `ServingGroup`s simultaneously could incapacitate all affected groups, causing a massive drop in inference capacity.

## Goal
Implement a mechanism that guarantees **ServingGroup-level rolling protection**. Regardless of how pods are physically distributed or co-located on nodes, the system must enforce that only one `ServingGroup` is disrupted/migrated at any given time.

## Design Overview: Eviction Webhook
Instead of relying on PDBs, we will implement a `ValidatingAdmissionWebhook` that intercepts `pods/eviction` requests.

- **Group-Aware Interception**: The webhook identifies the target Pod's `ServingGroup` and checks the overall health of the `ModelServing`.
- **Strict Ordering**: 
  - If all groups are healthy, the eviction is **Allowed** (initiating the disruption of the target group).
  - If the target pod belongs to the group that is *already* currently disrupting, the eviction is **Allowed**.
  - If the target pod belongs to a *different* group while another group is still recovering, the eviction is **Denied** (HTTP 429). This forces `kubectl drain` to back off and wait until the recovering group is fully ready.

Detailed design, Mermaid flowcharts, and concrete disruption scenarios are documented in:
- `PROPOSAL_COMMIT.md` (this directory)
- `kthena/docs/proposal/modelserving-eviction-webhook.md`
