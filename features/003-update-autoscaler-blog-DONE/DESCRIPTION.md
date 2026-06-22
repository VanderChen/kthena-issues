# Update Autoscaler Blog Post

## Background
The current Autoscaler blog post contains some inaccuracies and needs clarification on several points regarding architecture, metrics, and policy/binding logic.

## Requirements
1.  **Architecture:** Clarify that Kthena Autoscaler is not an independent component but a controller within `kthena-controller-manager`.
2.  **Metrics:** Emphasize the importance of business metrics from inference engines (e.g., vLLM) over node resource metrics. Mention that the Autoscaler can fetch these metrics directly from Pods.
3.  **Policy & Binding:** Clarify the relationship between `AutoscalePolicy` (generic) and `AutoscaleBinding`. Explain how binding determines scaling behavior:
    *   Whole group scaling (fixed role ratio).
    *   Independent role scaling (PD heterogeneous scaling).
4.  **Integration:** Merge or remove the separate "Integration" section as the Autoscaler is now part of the controller manager.
