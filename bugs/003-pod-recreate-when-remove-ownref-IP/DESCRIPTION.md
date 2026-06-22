# Bug Description: Pod not recreated when OwnerReference is missing

## Summary
When a Pod exists with the correct labels but is missing the `OwnerReference` pointing to the `ModelServing` resource, the controller fails to recreate the Pod or take ownership. Instead, it enters a reconcile loop where it attempts to create the Pod, receives an `AlreadyExists` error from the API server, and fails to resolve the conflict by deleting the "orphaned" Pod.

## Steps to Reproduce
1. Manually create a Pod with labels matching a `ModelServing` but without an `OwnerReference`.
2. Apply the `ModelServing` resource.
3. Observe that the Pod remains orphaned and no new Pod is successfully created by the controller.

## Expected Behavior
The controller should detect that the existing Pod is not owned by it (UID mismatch or missing ownerRef), delete the orphaned Pod, and create a new one with the correct `OwnerReference`.

## Actual Behavior
The controller logs that the Pod is "outdated" but only re-enqueues itself without deleting the conflicting Pod. The `OwnerReference` is never added, and the replica is not considered "ready" by the controller's internal store.

## Environment Details
- Kthena Version: dev
- Kubernetes Version: v1.31.0 (Kind)
- OS: darwin/arm64
