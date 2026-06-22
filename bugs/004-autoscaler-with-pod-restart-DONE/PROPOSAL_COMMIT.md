# Proposal: Fix Autoscaler skipping pods with restarts

## Problem
The `MetricCollector` in the autoscaler marks the entire metric collection as failed if any pod has a `RestartCount > 0`. This is because `instanceInfo.IsFailed` is set to true if `inferControllerUtils.ContainerRestarted(pod)` returns true. Since `RestartCount` is cumulative, once a pod restarts, autoscaling for that workload is permanently disabled until the pod is deleted.

## Solution
Modify `fetchMetricsFromPods` to:
1. Remove `inferControllerUtils.ContainerRestarted(pod)` from the global failure condition.
2. Only attempt to collect metrics from pods that are currently `Running` and `Ready`.
3. Count instances that are not ready/running instead of failing the entire collection.

## Results
### Implementation
- Modified `InstanceInfo` struct in `kthena/pkg/autoscaler/autoscaler/metric_collector.go` to use `UnreadyCount` and `FailedCount` instead of boolean `IsReady` and `IsFailed`.
- Updated `fetchMetricsFromPods` to skip pods that are not `Ready` or have `Failed`, but continue collecting from healthy pods.
- Removed the check for `inferControllerUtils.ContainerRestarted(pod)` which was incorrectly causing the entire collection to fail if any pod had ever restarted.
- Updated `UpdateMetrics` to use the new counts and only return early if no metrics were collected and there are unhealthy pods.

### Verification Results
- Added a new unit test `TestUpdateMetrics_WithRestartedPod` in `kthena/pkg/autoscaler/autoscaler/metric_collector_test.go`.
- The test confirms that a pod with `RestartCount: 5` still has its metrics collected if it is in `Running` phase and `Ready` condition.
- Ran all unit tests in `kthena/` and they passed.

```bash
$ cd kthena && go test -v ./pkg/autoscaler/autoscaler/
=== RUN   TestUpdateMetrics_WithRestartedPod
I0426 17:21:42.324699   49967 metric_collector.go:135] "fetch metrics from pods start"
--- PASS: TestUpdateMetrics_WithRestartedPod (0.00s)
PASS
ok      github.com/volcano-sh/kthena/pkg/autoscaler/autoscaler  0.782s
```

## Commit Hash
6f9ecb652dcf8ccc1968081520d814b3437ce6ad
