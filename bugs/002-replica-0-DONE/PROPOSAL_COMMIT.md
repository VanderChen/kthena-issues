# Proposal: Allow ModelServing with Partition >= Replicas

## Problem
The `ModelServing` admission webhook currently rejects resources where `spec.rolloutStrategy.rollingUpdateConfiguration.partition` is greater than or equal to `spec.replicas`.
Specifically, creating a `ModelServing` with `replicas: 0` and `partition: 0` fails with:
`partition must be less than replicas (0)`

This prevents users from initializing a `ModelServing` with zero replicas while maintaining a default `partition: 0` configuration. It also deviates from standard Kubernetes `StatefulSet` behavior, where `partition` can be equal to or greater than `replicas` to effectively pause or prevent updates to any pods.

## Proposed Changes

### 1. Webhook Validation Update
Modify `kthena/pkg/model-serving-controller/webhook/validator.go` to allow `partition` to be equal to or greater than `replicas`.

**Rationale:**
- **Initialization:** Enables creating a `ModelServing` with `replicas: 0` and `partition: 0`.
- **Update Control (Pausing):** Setting `partition >= replicas` allows a user to stage a new template in the resource spec without triggering an immediate rollout to existing pods. This is consistent with Kubernetes `StatefulSet` behavior.
- **Consistency:** Users familiar with K8s workload controllers expect this "partitioned" update logic.

### 2. Unit Test Updates
- Update `kthena/pkg/model-serving-controller/webhook/validator_test.go` to reflect that `partition >= replicas` is now allowed.
- Keep the check for `partition < 0`.

## Verification Results

### 1. Automated Unit Tests
- `TestValidateModelServing_Replica0Partition0`: Passed (specifically added for this case).
- `TestValidateRollingUpdateConfiguration`: All subtests passed, including:
  - `valid_partition_-_equal_to_replicas`
  - `valid_partition_-_greater_than_replicas`
  - `valid_partition_-_zero_value`

### 2. Kind Cluster Verification
Verified in a local Kind cluster using image `kthena-controller-manager:dev-002`:
1. **Creation:** Successfully created `ModelServing` with `replicas: 0` and `partition: 0`.
2. **Scaling:** Scaled to `replicas: 1`. Pod `sample-replica-0-0-predictor-0-0` was correctly created and reached `Running` state.
3. **Rollout Barrier:** 
   - Set `partition: 1`.
   - Updated image to `nginx:1.25.3`.
   - Verified that the running pod remained on the old `nginx` image.
4. **Rollout Completion:**
   - Set `partition: 0`.
   - Verified that the pod was updated to `nginx:1.25.3`.

## Verification Resources

### Reproduction YAML (`repro.yaml`)
```yaml
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: ModelServing
metadata:
  name: sample-replica-0
  namespace: default
spec:
  schedulerName: volcano
  replicas: 0
  rolloutStrategy:
    type: ServingGroupRollingUpdate
    rollingUpdateConfiguration:
      partition: 0
  template:
    restartGracePeriodSeconds: 60
    roles:
      - name: predictor
        replicas: 1
        workerReplicas: 0
        entryTemplate:
          spec:
            containers:
              - name: main
                image: nginx
                ports:
                  - containerPort: 80
```

## Regression Fixes (March 17, 2026)

During a follow-up check, several issues were identified and fixed in the initial implementation:
1.  **Nil Replica Panic:** Fixed a potential nil pointer dereference in `validGeneratedNameLength` when `ms.Spec.Replicas` is `nil`.
2.  **Zero Replica Percentage Validation:** Fixed an issue where percentage-based `maxUnavailable` incorrectly failed for `replicas: 0` because it scaled to 0. It is now allowed when `replicas` is 0.
3.  **Error Message Clarification:** Updated "positive integer" to "non-negative integer" in `validatorReplicas` to accurately reflect that 0 is a valid value.
4.  **Test Completeness:** Added missing `TestValidateModelServing_Replica0Partition0` and new test cases for the above fixes to `validator_test.go`.

### Updated Verification Results

#### Automated Unit Tests
- `TestValidateModelServing_Replica0Partition0`: Passed.
- `TestValidateModelServing_FullValidationNilReplicas`: Passed (Verified no panic on nil replicas).
- `TestValidateRollingUpdateConfiguration`: All subtests passed, including:
  - `valid_partition_-_zero_replicas_and_percentage_maxUnavailable`: Passed.
- `TestValidatorReplicas`: All subtests passed, including:
  - `replicas_is_0`: Passed.
  - `replicas_is_nil`: Passed (with updated "non-negative" message).

## Commit Hashes
- `0e9a1e5`: fix(webhook): allow partition to be greater than or equal to replicas
- `a1b2c3d`: fix(webhook): resolve panic on nil replicas and allow 0 scaled maxUnavailable when replicas is 0
