# Proposal: Add Role and Cost Examples to Autoscaler Blog

## Goal
Enhance the Autoscaler blog with detailed YAML examples for Role-level scaling and Cost-aware heterogeneous scaling.

## Proposed Changes

### 1. Update Section 4.2 (Role Binding)
- Add a simplified `ModelServing` YAML that defines `prefill` and `decode` roles.
- This provides the necessary context for the subsequent `AutoscaleBinding` example.

### 2. Add Section 7 (Cost-aware Optimization)
- Add a new section titled "Cost-aware Optimization with Heterogeneous Scaling" (and its Chinese equivalent).
- Provide a YAML example of an `AutoscaleBinding` using `heterogeneousTarget`.
- Explain how the `cost` field and `costExpansionRatePercent` work together to prioritize cheaper resources (e.g., A100 vs H100).

### 3. Localization
- Apply all changes to `kthena/docs/kthena/blog/autoscaler/index.md` and `kthena/docs/kthena/blog/autoscaler/index_zh.md`.

## Proposed YAML for Role Scaling
```yaml
# Simplified ModelServing with Roles
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: ModelServing
metadata:
  name: deepseek-serving
spec:
  template:
    roles:
    - name: prefill
      replicas: 1
      # ... containers config ...
    - name: decode
      replicas: 2
      # ... containers config ...
---
# Binding to a specific Role
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: AutoscalingPolicyBinding
metadata:
  name: decode-independent-binding
spec:
  policyRef:
    name: llm-scaling-policy
  homogeneousTarget:
    target:
      targetRef:
        kind: ModelServing
        name: deepseek-serving
      subTargets:
        kind: Role
        name: decode
    minReplicas: 2
    maxReplicas: 8
```

## Proposed YAML for Cost-aware Scaling
```yaml
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: AutoscalingPolicyBinding
metadata:
  name: heterogeneous-cost-binding
spec:
  policyRef:
    name: vllm-queue-policy
  heterogeneousTarget:
    params:
    - target:
        targetRef:
          kind: ModelServing
          name: deepseek-h100
      cost: 100
      minReplicas: 1
      maxReplicas: 10
    - target:
        targetRef:
          kind: ModelServing
          name: deepseek-a100
      cost: 50
      minReplicas: 1
      maxReplicas: 20
    costExpansionRatePercent: 200
```

## Verification
- Review Markdown rendering.
- Ensure YAML schema matches `kthena/pkg/apis/workload/v1alpha1/autoscalingpolicybinding_types.go`.
