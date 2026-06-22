# Proposal: kthena-controller-manager performance baseline

## Branch

- Current workspace branch at proposal start: `fix/007-eviction-currentready-recovery`

## Objective

Design a repeatable baseline that measures how `kthena-controller-manager`
resource usage changes with:

- total managed Pod count;
- total ModelServing count;
- Autoscaler metric collection activity;
- create/update/delete reconcile churn.
- reconcile completion speed compared with Kubernetes Deployment at the same
  Pod count.

## Source Analysis

### Controller-manager process shape

`kthena-controller-manager` starts the webhook server and the enabled
controllers in one process. Relevant flags:

- `--controllers` chooses `modelserving`, `modelbooster`, and/or `autoscaler`.
- `--workers` controls ModelServing/ModelBooster worker goroutines; default is
  `5`.
- `--kube-api-qps` and `--kube-api-burst` default to client-go values when not
  set.
- `--debug-port` only exposes ModelServing datastore cache dump, not pprof or
  Prometheus process metrics.

Source references:

```text
cmd/kthena-controller-manager/main.go:73-91
cmd/kthena-controller-manager/main.go:193-208
pkg/controller/controller.go:75-144
charts/kthena/charts/workload/values.yaml:25-44
```

The default Helm resource envelope is:

```text
requests: 100m CPU, 128Mi memory
limits:   500m CPU, 512Mi memory
```

This should be the first baseline target. If the controller exceeds it under
reasonable object counts, the benchmark should report the object scale where
that happens.

### Expected memory growth drivers

1. Multiple informer caches exist in the same process.

   - ModelServing controller maintains filtered Pod and Service informers plus
     a ModelServing informer.
   - Autoscaler maintains a separate filtered Pod informer plus ModelServing,
     AutoscalingPolicy, and AutoscalingPolicyBinding informers.
   - The webhook path starts its own Pod and ModelServing informers when the
     webhook process is enabled.

   This means Pod and ModelServing objects can be cached more than once in the
   same controller-manager process.

   Source references:

   ```text
   pkg/model-serving-controller/controller/model_serving_controller.go:116-126
   pkg/autoscaler/controller/autoscale_controller.go:65-91
   cmd/kthena-controller-manager/main.go:193-200
   ```

2. ModelServing controller keeps an additional in-memory datastore of
   ServingGroups, roles, and running Pod names.

   The datastore is separate from informer caches, so memory growth is roughly:

   ```text
   informer Pod/Service/PodGroup/CR objects
   + ModelServing datastore groups/roles/runningPods
   + workqueue/backoff state
   + Kubernetes Events buffering
   ```

   Source references:

   ```text
   pkg/model-serving-controller/controller/model_serving_controller.go:96-102
   pkg/model-serving-controller/datastore/store.go:100-128
   pkg/model-serving-controller/datastore/store.go:131-161
   ```

3. Autoscaler stores per-binding scaler/optimizer objects and per-pod
   histogram snapshots in sliding windows.

   Histogram-heavy metrics and many AutoscalingPolicyBindings can increase heap
   independently from the number of ModelServings.

   Source references:

   ```text
   pkg/autoscaler/autoscaler/metric_collector.go:102-131
   pkg/autoscaler/autoscaler/metric_collector.go:135-183
   pkg/autoscaler/autoscaler/metric_collector.go:189-235
   pkg/autoscaler/autoscaler/optimizer.go:117-131
   ```

### Expected CPU growth drivers

1. ModelServing reconcile is per ModelServing key, but each sync does several
   passes over its groups and roles:

   ```text
   syncServingGroupReplicas
   syncRoleWithinServingGroups
   manageRollingUpdate
   syncHeadlessServices
   UpdateModelServingStatus
   ```

   Source references:

   ```text
   pkg/model-serving-controller/controller/model_serving_controller.go:532-578
   ```

2. Several datastore reads copy slices and sort by ordinal. This makes repeated
   reconciliation of large ModelServings sensitive to group and role counts.

   Source references:

   ```text
   pkg/model-serving-controller/datastore/store.go:107-128
   pkg/model-serving-controller/datastore/store.go:131-161
   ```

3. Scale-up and scale-down paths create/delete resources sequentially. Large
   object waves are likely to be API-server and client-go QPS sensitive.

   Source references:

   ```text
   pkg/model-serving-controller/controller/model_serving_controller.go:640-684
   pkg/model-serving-controller/controller/model_serving_controller.go:925-952
   pkg/model-serving-controller/controller/model_serving_controller.go:1968-2048
   ```

4. Role reconciliation checks every known role and uses informer indexes to
   verify expected Pod count. This is expected to scale with:

   ```text
   ModelServings * replicas * roles * roleReplicas
   ```

   Source references:

   ```text
   pkg/model-serving-controller/controller/model_serving_controller.go:957-1005
   pkg/model-serving-controller/controller/model_serving_controller.go:1666-1686
   ```

5. Autoscaler is periodic and global. Every sync period it lists all bindings,
   prunes maps, and schedules each binding sequentially.

   Source references:

   ```text
   pkg/autoscaler/controller/autoscale_controller.go:113-116
   pkg/autoscaler/controller/autoscale_controller.go:124-170
   ```

6. Autoscaler metric collection lists matching Pods, then performs synchronous
   HTTP scrapes and Prometheus text parsing for each Pod. This creates a clear
   CPU and latency axis:

   ```text
   bindings * matchedPodsPerBinding * metricsPayloadSize
   ```

   Source references:

   ```text
   pkg/autoscaler/autoscaler/metric_collector.go:102-131
   pkg/autoscaler/autoscaler/metric_collector.go:135-183
   pkg/autoscaler/autoscaler/metric_collector.go:189-235
   ```

### Likely reconcile-speed bottlenecks

The observed concern is that at the same Pod count, ModelServing feels slower
than a native Deployment. Based on the current implementation, compare these
paths explicitly:

1. ModelServing creates one PodGroup per ServingGroup before creating Pods.
   Deployment does not have this extra object in the normal path.

   Source references:

   ```text
   pkg/model-serving-controller/controller/model_serving_controller.go:710-720
   ```

2. ModelServing creates Pods sequentially inside each ServingGroup and role.
   Deployment's ReplicaSet controller also loops, but the Kthena path adds
   per-role template hashing, plugin chain construction hooks, PodGroup
   annotation, datastore writes, and Kubernetes Event emission.

   Source references:

   ```text
   pkg/model-serving-controller/controller/model_serving_controller.go:925-952
   pkg/model-serving-controller/controller/model_serving_controller.go:2059-2099
   pkg/model-serving-controller/controller/model_serving_controller.go:2101-2164
   ```

3. Each ModelServing reconcile runs multiple passes after create/scale:
   role sync, rolling update checks, headless service sync, and status update.
   Deployment's basic reconcile path is narrower for simple replica management.

   Source references:

   ```text
   pkg/model-serving-controller/controller/model_serving_controller.go:532-578
   ```

4. Status completion depends on informer events and the controller's in-memory
   datastore. If Pods are created but informer cache and store status lag,
   `status.observedGeneration`, `status.replicas`, and `availableReplicas` can
   complete later than Pod object creation.

   Source references:

   ```text
   pkg/model-serving-controller/controller/model_serving_controller.go:318-370
   pkg/model-serving-controller/controller/model_serving_controller.go:1746-1936
   ```

5. With several roles or workers, one top-level ModelServing replica maps to
   multiple Pods and role records. Native Deployment replicas map directly to
   Pods. Same Pod count comparisons must normalize this object fan-out.

## Measurement Design

### Primary measurements

For each scenario, sample these values at 5-second intervals:

- controller-manager CPU usage:
  - preferred: Prometheus/cAdvisor `container_cpu_usage_seconds_total`;
  - fallback without metrics-server/Prometheus: read cgroup `cpu.stat` from the
    controller container and compute `usage_usec` delta per wall-clock second.
- controller-manager memory:
  - preferred: Prometheus/cAdvisor `container_memory_working_set_bytes`;
  - fallback: read cgroup `memory.current` and, when available,
    `memory.peak`.
- Kubernetes object counts:
  - ModelServings;
  - Pods with `modelserving.volcano.sh/group-name`;
  - Services;
  - PodGroups;
  - AutoscalingPolicies and AutoscalingPolicyBindings.
- controller health:
  - restart count;
  - reconcile error log counts;
  - final observedGeneration convergence for test ModelServings.
- reconcile completion speed:
  - `t_submit`: timestamp immediately before `kubectl apply`, `kubectl patch`,
    or API request;
  - `t_generation_visible`: target object generation observed through GET;
  - `t_pod_objects_complete`: all expected Pod names exist;
  - `t_controller_observed`: ModelServing `status.observedGeneration` equals
    metadata generation;
  - `t_status_replicas_complete`: ModelServing `status.replicas` equals
    expected top-level replicas;
  - `t_available_complete`: ModelServing `availableReplicas` equals expected
    replicas, only in tests where Pods can become Ready;
  - `t_deployment_available`: Deployment `.status.availableReplicas` equals
    expected replicas for the native baseline.

Suggested fallback sampler:

```bash
kubectl exec -n kthena-system deploy/kthena-controller-manager -- \
  sh -c 'date +%s; cat /sys/fs/cgroup/cpu.stat; cat /sys/fs/cgroup/memory.current; cat /sys/fs/cgroup/memory.peak 2>/dev/null || true'
```

If metrics-server is installed, also capture:

```bash
kubectl top pod -n kthena-system -l app.kubernetes.io/component=kthena-controller-manager --containers
```

### Run phases

Each scenario should have:

1. Clean baseline: controller running with no test workload for at least 2
   minutes.
2. Ramp-up: create workload in waves, for example 10%, 25%, 50%, 100% of the
   target object count.
3. Steady state: hold for 5-10 minutes.
4. Churn: apply updates, scale changes, or restarts for 5 minutes.
5. Cleanup: delete test namespace and wait for controller memory to stabilize.

For every phase, record:

- p50/p95/p99 CPU over the phase;
- max memory and final memory after phase;
- time to converge, split into Pod object creation, controller status
  observation, and Ready/Available convergence;
- error log count;
- object count at phase end.

### Completion speed instrumentation

The first version should measure externally with `kubectl get -w` or polling at
1-second intervals, so the benchmark does not require production code changes.
If external polling shows ModelServing is materially slower than Deployment, add
temporary benchmark instrumentation after approval to log per-step durations in:

```text
syncServingGroupReplicas
scaleUpServingGroups
CreatePodsForServingGroup
CreatePodsByRole
syncRoleWithinServingGroups
syncHeadlessServices
UpdateModelServingStatus
```

The goal is to distinguish these bottleneck classes:

- API write bottleneck: time spent creating PodGroups/Pods/Services.
- informer/cache bottleneck: Pod objects exist but controller status lags.
- datastore/sort bottleneck: CPU rises during repeated group/role scans.
- status-update bottleneck: reconcile work completes but status conflicts or
  retries delay observedGeneration.
- scheduler/readiness bottleneck: Pod objects exist but Ready/Available lags.

## Test Matrix

### Scenario A: idle controller baseline

Purpose: establish process floor for enabled controller combinations.

Variants:

```text
A1: controllers=modelserving
A2: controllers=modelserving,autoscaler
A3: controllers=*
A4: controllers=* with eviction webhook enabled
```

Expected signal:

- Memory delta from enabling Autoscaler and webhook shows duplicate informer
  cache overhead before workloads exist.
- CPU should be near-zero except informer resync/startup noise.

### Scenario B: ModelServing count scale

Purpose: isolate ModelServing CR count from Pod count.

Shape:

```text
N ModelServings
replicas: 1
roles: 1
role replicas: 1
workerReplicas: 0
expected Pods: N
```

Suggested points:

```text
N = 10, 50, 100, 250, 500, 1000
```

Measure:

- memory per ModelServing;
- startup sync time after controller restart;
- create wave convergence time;
- status update pressure.

### Scenario C: Pod count scale

Purpose: isolate Pod count and ServingGroup count.

Shape:

```text
M ModelServings, each with R top-level replicas
roles: 1 or 2
role replicas: 1
workerReplicas: 0
expected Pods: M * R * roles
```

Suggested points:

```text
100, 250, 500, 1000, 2000 Pods
```

Use multiple ModelServings rather than one giant object for part of the matrix:

```text
C1: 1 ModelServing x 1000 replicas
C2: 10 ModelServings x 100 replicas
C3: 100 ModelServings x 10 replicas
```

This separates per-ModelServing reconcile overhead from aggregate Pod informer
memory.

### Scenario C-D: Deployment speed control

Purpose: provide a native Kubernetes control group for the user's observation
that ModelServing is slower than Deployment at the same Pod count.

For each Pod-count point in Scenario C, create an equivalent Deployment:

```text
Deployment replicas = expected ModelServing Pod count
same container image and command
same namespace class and resource requests
default scheduler for both, unless Volcano is healthy and intentionally tested
```

Record side-by-side:

```text
ModelServing: t_submit -> t_pod_objects_complete
ModelServing: t_submit -> t_controller_observed
ModelServing: t_submit -> t_status_replicas_complete
ModelServing: t_submit -> t_available_complete
Deployment:   t_submit -> all ReplicaSet Pod objects exist
Deployment:   t_submit -> observedGeneration complete
Deployment:   t_submit -> availableReplicas complete
```

Interpretation:

- If Pod object creation is slower for ModelServing, focus on PodGroup creation,
  sequential CreatePods paths, API QPS/burst, and event emission.
- If Pod object creation is similar but status completion is slower, focus on
  informer events, in-memory store transitions, `UpdateModelServingStatus`, and
  status update conflicts.
- If Available is slower for both, the bottleneck is likely scheduler, image
  pull, readiness, or node capacity rather than kthena-controller-manager.

### Scenario D: role and worker density

Purpose: capture cost of extra role bookkeeping and services.

Variants:

```text
D1: 1 role, role replicas 1, workerReplicas 0
D2: 2 roles, role replicas 1, workerReplicas 0
D3: 2 roles, role replicas 2, workerReplicas 0
D4: 2 roles, role replicas 2, workerReplicas 2
```

Keep total top-level replicas fixed, for example `100`, so the test shows the
incremental cost of roles/workers.

### Scenario E: reconcile churn

Purpose: stress workqueue, API calls, status updates, and datastore sorting.

Operations:

```text
E1: scale replicas 100 -> 200 -> 100 every 30s
E2: update role replicas 1 -> 2 -> 1 every 30s
E3: rolling update by changing a harmless env var on the pod template
E4: delete 5% of managed Pods every 30s and let controller recreate
```

Measure:

- CPU spikes;
- convergence time per operation, split by object creation, observedGeneration,
  status replicas, and availability;
- memory high-water mark;
- reconcile error logs;
- API throttling or rate-limit symptoms.

### Scenario F: Autoscaler homogeneous metrics

Purpose: measure runtime metric scrape overhead with one target per binding.

Shape:

```text
N ModelServings
N AutoscalingPolicyBindings
one HomogeneousTarget per binding
metrics endpoint returns fixed Prometheus text
```

Suggested points:

```text
bindings = 1, 10, 50, 100, 250
pods per binding = 1, 5, 10
metrics payload = small gauge-only, mixed gauge/counter/histogram, large histogram
```

Important: use Ready Pods for this scenario because Autoscaler scrapes Pod IPs
directly. For Kind, omit `schedulerName: volcano` if Volcano is not healthy and
use the default scheduler.

### Scenario G: Autoscaler heterogeneous optimizer

Purpose: measure multi-target optimization and duplicated scrape paths.

Shape:

```text
one AutoscalingPolicyBinding with HeterogeneousTarget
params = 2, 5, 10 target ModelServings
each target has 1, 5, or 10 Ready metric Pods
```

Expected signal:

- CPU grows with `params * podsPerTarget * metricsPayload`.
- memory grows with collector sliding windows per target.

### Scenario H: degraded metrics path

Purpose: quantify bad-case Autoscaler cost.

Variants:

```text
H1: metric endpoint connection refused
H2: endpoint delays close to AutoscaleCtxTimeoutSeconds
H3: invalid Prometheus payload
H4: large payload with many unrelated metrics
```

This scenario is important because metric scraping is synchronous per Pod in
the current collector implementation.

## Test Workload Design

Use a lightweight fake runtime container for Autoscaler scenarios. It should:

- expose `/metrics` on the configured port;
- return configurable metric payload sizes;
- optionally delay responses or return invalid payloads;
- run with tiny CPU/memory requests.

For pure controller object scale scenarios, use simple sleep containers and
omit AutoscalingPolicyBindings.

When only object creation convergence is being measured, Pods do not need to be
Ready. When Autoscaler metrics are measured, Pods must be Ready and have Pod IPs.

## Acceptance Criteria For Baseline

The baseline is complete when the report includes:

- resource curves for CPU and memory against Pod count;
- resource curves for CPU and memory against ModelServing count;
- Autoscaler overhead curves for binding count, Pod count per binding, and
  metrics payload size;
- ModelServing vs Deployment reconcile completion curves at equal Pod counts;
- a bottleneck classification for any slower ModelServing phase: API writes,
  informer/cache lag, datastore/status computation, status update conflicts, or
  scheduler/readiness;
- recommended default resource requests/limits for small, medium, and large
  deployments;
- known bottlenecks observed in logs or metrics;
- reproducible manifests/scripts checked into the feature task directory.

Suggested deployment size buckets:

```text
small:  <= 100 Pods, <= 20 ModelServings
medium: <= 1000 Pods, <= 200 ModelServings
large:  > 1000 Pods or > 200 ModelServings
```

## Implementation Plan After Approval

1. Add benchmark manifests and shell scripts under this task directory, not in
   production code.
2. Add a fake metrics runtime manifest for Autoscaler scenarios.
3. Add a sampler script that records cgroup CPU/memory, object counts, and
   controller logs into timestamped files.
4. Run a small smoke test in Kind to validate the harness.
5. Run the matrix incrementally, stopping if controller-manager hits its Helm
   resource limits or the Kind cluster saturates.
6. Summarize results and recommended resource envelopes in this file.

## Open Questions

- Should the first baseline target the current local branch/image
  `dev-007-same-name-fix-v2`, or should we rebuild from `main` before measuring?
- Should the baseline use default scheduler to keep Pods Ready when Volcano is
  unhealthy, or require a healthy Volcano scheduler before executing all runs?
- Is Prometheus available in the intended benchmark environment, or should the
  cgroup sampler be the canonical measurement path?
