# Add Role and Cost Examples to Autoscaler Blog

## Background
The Autoscaler documentation (blog post) needs more concrete examples for two advanced features:
1.  **Role-level Scaling:** Showing how to scale a specific role (e.g., `decode`) within a `ModelServing` deployment.
2.  **Cost-aware Heterogeneous Scaling:** Showing how to configure `cost` for different targets in a `heterogeneousTarget` binding to optimize resource usage.

## Requirements
1.  Add a simplified `ModelServing` example with multiple roles (prefill, decode) to provide context for role-level scaling.
2.  Add a dedicated section at the end of the blog for "Cost-aware Optimization" with a YAML example showing `heterogeneousTarget`, `cost`, and `costExpansionRatePercent`.
3.  Update both English (`index.md`) and Chinese (`index_zh.md`) versions.
4.  Fix any typos found in existing YAML snippets (e.g., ensuring `subTargets` field is correctly used).
