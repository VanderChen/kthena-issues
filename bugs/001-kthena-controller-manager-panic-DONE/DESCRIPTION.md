# Bug Description

## Summary
The pod created by kthena-controller-manager will have ownref, like

```yaml
ownerReferences:
  - apiVersion: workload.serving.volcano.sh/v1alpha1
    blockOwnerDeletion: true
    controller: true
    kind: ModelServing
    name: sample-replica-0
    uid: ff97c43f-ac7d-48a6-8ea0-656c79adfba0
```

when remove this ownref, the pod needs recreate.

## Steps to Reproduce
1. create ModelServing workload
2. remove pod ownref


## Expected Behavior
the pods need recreate

## Actual Behavior
no pods recreate

## Environment Details
- Kthena Version:
- Kubernetes Version:
- OS:
- Relevant Logs/Events:
