# Bug Description: ModelServing Creation Fails with Replicas: 0 and Partition: 0

## Summary
Creating a `ModelServing` resource with `spec.replicas: 0` and `spec.rolloutStrategy.rollingUpdateConfiguration.partition: 0` fails due to an admission webhook validation error. The validator incorrectly mandates that the `partition` value must be strictly less than the number of `replicas`.

In scenarios where a user wishes to initialize a `ModelServing` resource with zero replicas (e.g., for later scaling or template preparation) but maintain a standard rollout configuration, `partition: 0` is a valid and expected setting.

## Reproduction Manifest
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
        entryTemplate:
          spec:
            containers:
              - name: main
                image: nginx
```

## Steps to Reproduce
1. Attempt to apply the above manifest to a cluster with Kthena installed:
   ```bash
   kubectl apply -f sample-replica-0.yaml
   ```

## Actual Behavior
The admission webhook returns the following error:
`admission webhook "validate-workload-ai-v1alpha1-modelserving.volcano.sh" denied the request: validation failed: - spec.rolloutStrategy.rollingUpdateConfiguration.partition: Invalid value: 0: partition must be less than replicas (0)`

## Expected Behavior
The resource should be created successfully. A `partition` value equal to or greater than the number of `replicas` should be permitted, effectively indicating that no replicas are currently targeted for the update (consistent with Kubernetes StatefulSet partition behavior).

## Environment Details
- Kthena Version: Latest
- Kubernetes Version: 1.25+
- OS: Darwin/Linux

