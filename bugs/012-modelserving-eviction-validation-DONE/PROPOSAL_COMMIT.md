# Bug Fix Proposal & Implementation

## Analysis
The ModelServing webhook already has `validateEvictionStrategy`, but the current
validation is incomplete for an explicitly configured eviction budget.

Current behavior observed from `pkg/model-serving-controller/webhook/validator.go`:

- `ServingGroup` mode only validates `minAvailable` when the field is non-nil.
  Missing `minAvailable` is accepted and the runtime eviction handler later
  defaults it to `1`.
- `Role` mode validates `roleMinAvailable` entries when present, including
  unknown role keys and invalid percentage strings, but a nil or empty map is
  accepted.
- Integer-or-percent syntax is validated, but values are not bounded against the
  applicable total replica count. For example, `minAvailable: 5` can be admitted
  for a `ModelServing` with `spec.replicas: 3`.

This makes invalid or ambiguous eviction configuration visible only later during
eviction handling. Admission should reject these cases up front.

## Proposed Solution
Enhance `validateEvictionStrategy` so configured eviction protection has an
explicit and valid min-availability threshold:

1. Apply the effective protection level:
   - Treat an empty protection level as `ServingGroup`, matching the CRD default.
   - Continue relying on CRD enum validation for unsupported non-empty values,
     but add webhook validation if needed for direct unit coverage.
2. For `ServingGroup` protection:
   - Require `evictionStrategy.minAvailable`.
   - Validate it with the existing integer-or-percent validation helper.
   - Resolve it using the same rounding behavior as eviction handling
     (`intstr.GetScaledValueFromIntOrPercent(..., replicas, true)`).
   - Reject values that resolve above `spec.replicas`.
3. For `Role` protection:
   - Require `roleMinAvailable` to be non-empty.
   - Keep the existing behavior that only listed roles are protected; do not
     require every role to be present in the map.
   - Validate every map key against `spec.template.roles[*].name`.
   - Validate each value as integer-or-percent.
   - Resolve each value against that role's replicas using the same rounding
     behavior as eviction handling.
   - Reject values that resolve above the role's replica count.
4. Keep `minAvailable` ignored in Role mode to preserve the behavior introduced
   by the role-specific eviction-budget work.

## Implementation Details
- Changes made:
  - Updated `pkg/model-serving-controller/webhook/validator.go` to require
    explicit eviction min thresholds and validate resolved values against the
    applicable replica count.
  - Extended
    `pkg/model-serving-controller/webhook/validator_test.go` with focused
    ServingGroup and Role eviction validation cases.
  - Added server-side dry-run verification manifests in this task folder:
    - `invalid-servinggroup-missing-minavailable.yaml`
    - `invalid-servinggroup-minavailable-above-replicas.yaml`
    - `invalid-role-missing-roleminavailable.yaml`
    - `invalid-role-roleminavailable-above-replicas.yaml`
    - `valid-servinggroup-minavailable.yaml`
    - `valid-role-roleminavailable.yaml`
- Components affected:
  - ModelServing validating webhook only.
  - No CRD type change is expected.
  - No generated code change is expected.

## Test Plan
- Unit tests:
  - `ServingGroup` eviction strategy without `minAvailable` is rejected.
  - Valid `ServingGroup` integer and percent `minAvailable` are accepted.
  - `ServingGroup` `minAvailable` above `spec.replicas` is rejected.
  - Invalid `ServingGroup` values such as negative numbers and percentages above
    100 are rejected.
  - `Role` eviction strategy without `roleMinAvailable` is rejected.
  - Empty `roleMinAvailable` map is rejected.
  - Unknown role keys remain rejected.
  - Valid role-specific integer and percent values are accepted.
  - Role-specific values above the role replica count are rejected.
- Regression command after implementation:
  - `go test ./pkg/model-serving-controller/webhook/...`
  - `go test $(go list ./... | grep -v /e2e)`

## Kind Verification Plan
After code changes are approved and implemented:

1. Build the controller-manager binary for the local Kind architecture.
2. Build and load a dev controller-manager image.
3. Deploy it with Helm into the local Kind cluster.
4. Verify admission behavior with `kubectl apply --dry-run=server` or real
   `kubectl apply` for invalid and valid `ModelServing` manifests:
   - invalid missing `minAvailable`;
   - invalid `minAvailable` above replicas;
   - invalid missing or empty `roleMinAvailable`;
   - valid `ServingGroup` and `Role` eviction configurations.
5. Record commands, webhook rejection messages, and accepted manifests here.

## Verification Results
- Unit Tests:
  - `go test ./pkg/model-serving-controller/webhook/...`
  - Result: passed.
- Regression Gate:
  - `go test $(go list ./... | grep -v /e2e)`
  - Result: passed.
- E2E Tests:
  - Not run; not requested and not part of the default workflow.
- Kind Verification:
  - Cluster: `kind`
  - Node architecture: `arm64`
  - Image: `kthena-controller-manager:dev-012`
  - Docker image ID:
    `sha256:cd4761ad8325871f90bc0b9350656ce9908f6156368b65c718992e2bbf32846e`
  - Helm command:
    `helm upgrade --install kthena ./charts/kthena --namespace kthena-system --create-namespace --set workload.controllerManager.image.repository=kthena-controller-manager --set workload.controllerManager.image.tag=dev-012 --set workload.controllerManager.image.pullPolicy=IfNotPresent`
  - Helm result: release `kthena`, revision 24, status `deployed`.
  - Rollout result:
    `deployment "kthena-controller-manager" successfully rolled out`.
  - Deployed pod:
    `kthena-controller-manager-6ff64fc487-r46q7`, `1/1 Running`, `0`
    restarts.
- Admission dry-run verification:
  - `invalid-servinggroup-missing-minavailable.yaml`: rejected with
    `spec.rolloutStrategy.evictionStrategy.minAvailable: Required value:
    minAvailable is required when evictionStrategy.protectionLevel is
    ServingGroup`.
  - `invalid-role-missing-roleminavailable.yaml`: rejected with
    `spec.rolloutStrategy.evictionStrategy.roleMinAvailable: Required value:
    roleMinAvailable is required when evictionStrategy.protectionLevel is Role`.
  - `invalid-servinggroup-minavailable-above-replicas.yaml`: rejected with
    `minAvailable (4) cannot exceed replicas (3)`.
  - `invalid-role-roleminavailable-above-replicas.yaml`: rejected with
    `roleMinAvailable (3) for role decode cannot exceed replicas (2)`.
  - `valid-servinggroup-minavailable.yaml`: accepted by server dry-run.
  - `valid-role-roleminavailable.yaml`: accepted by server dry-run.

## Associated Commits
- Commit ID: `771f2110`
- Branch: `fix/012-modelserving-eviction-validation`
