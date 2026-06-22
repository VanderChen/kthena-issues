# kthena-controller-manager performance baseline runbook

This runbook is for running the proposal in a production-like cluster that
already has Prometheus or a compatible Prometheus API.

The first pass should not change kthena implementation code. It should collect
enough evidence to answer:

- How do controller CPU and memory scale with ModelServing count and Pod count?
- How much extra cost does Autoscaler metrics collection add?
- Is ModelServing reconciliation slower than native Deployment at equal Pod
  count?
- If it is slower, which phase is dominant: API writes, cache/status lag,
  scheduling/readiness, or Autoscaler metric scraping?

## 0. Test Scope and Safety

Use a dedicated namespace and quota. Do not run this in a namespace shared with
real workloads.

Recommended namespace:

```bash
export PERF_NS=kthena-perf
export KTHENA_NS=kthena-system
kubectl create ns "${PERF_NS}" --dry-run=client -o yaml | kubectl apply -f -
```

Before each scenario, record:

```bash
kubectl version
kubectl get nodes -o wide
kubectl get deploy -n "${KTHENA_NS}" kthena-controller-manager -o yaml > controller-manager.before.yaml
kubectl get pod -n "${KTHENA_NS}" -l app.kubernetes.io/component=kthena-controller-manager -o wide
kubectl get validatingwebhookconfiguration,mutatingwebhookconfiguration | grep kthena || true
kubectl api-resources | grep -E 'modelservings|autoscalingpolicies|autoscalingpolicybindings|podgroups'
```

Recommended first matrix in a shared production-like cluster:

```text
10 ModelServings / 10 Pods
50 ModelServings / 50 Pods
100 ModelServings / 100 Pods
10 ModelServings / 500 Pods
1 ModelServing / 500 Pods
```

Only continue to 1000+ Pods after the controller-manager restart count is stable
and API server latency remains acceptable.

## 1. Confirm What Prometheus Can Observe

The current controller-manager chart exposes the webhook/health HTTPS port by
default. Unless your deployment has added a metrics endpoint, use kubelet/cAdvisor
and kube-state-metrics as the canonical source for CPU, memory, Pod count, and
object status.

Find the controller Pod:

```bash
export CM_POD="$(kubectl get pod -n "${KTHENA_NS}" -l app.kubernetes.io/component=kthena-controller-manager -o jsonpath='{.items[0].metadata.name}')"
echo "${CM_POD}"
```

Prometheus label discovery examples:

```bash
# Adjust PROM_URL for your environment.
export PROM_URL=http://prometheus-operated.monitoring.svc:9090

curl -G "${PROM_URL}/api/v1/series" \
  --data-urlencode 'match[]=container_cpu_usage_seconds_total{container="kthena-controller-manager"}' \
  --data-urlencode 'start='$(date -u -v-10M +%s) \
  --data-urlencode 'end='$(date -u +%s)

curl -G "${PROM_URL}/api/v1/series" \
  --data-urlencode 'match[]=kube_pod_container_status_restarts_total{container="kthena-controller-manager"}' \
  --data-urlencode 'start='$(date -u -v-10M +%s) \
  --data-urlencode 'end='$(date -u +%s)
```

If your shell does not support `date -v`, replace the timestamps manually:

```bash
START="$(date -u -d '10 minutes ago' +%s)"
END="$(date -u +%s)"
```

## 2. Core PromQL

Controller CPU:

```promql
sum by (pod) (
  rate(container_cpu_usage_seconds_total{
    namespace="kthena-system",
    container="kthena-controller-manager",
    pod=~"kthena-controller-manager.*"
  }[1m])
)
```

Controller memory:

```promql
max by (pod) (
  container_memory_working_set_bytes{
    namespace="kthena-system",
    container="kthena-controller-manager",
    pod=~"kthena-controller-manager.*"
  }
)
```

Controller restart count:

```promql
max by (pod) (
  kube_pod_container_status_restarts_total{
    namespace="kthena-system",
    container="kthena-controller-manager"
  }
)
```

API server request pressure from kthena-controller-manager, if API server request
metrics include user agent:

```promql
sum by (verb, resource, code) (
  rate(apiserver_request_total{
    useragent=~".*kthena.*|.*controller-manager.*"
  }[1m])
)
```

API server latency for write/list/watch operations:

```promql
histogram_quantile(
  0.99,
  sum by (le, verb, resource) (
    rate(apiserver_request_duration_seconds_bucket{
      verb=~"CREATE|UPDATE|PATCH|DELETE|LIST|WATCH",
      resource=~"pods|services|podgroups|modelservings|autoscalingpolicies|autoscalingpolicybindings"
    }[5m])
  )
)
```

ModelServing Pod count:

```promql
count(
  kube_pod_labels{
    namespace="kthena-perf",
    label_modelserving_volcano_sh_group_name!=""
  }
)
```

If kube-state-metrics does not expose the converted label above, use Kubernetes
directly:

```bash
kubectl get pod -n "${PERF_NS}" -l modelserving.volcano.sh/group-name --no-headers | wc -l
```

## 3. External Reconcile Timing

Use external timing first. This avoids changing code and separates controller
time from scheduling/readiness time.

For every test object, record these timestamps:

```text
t_submit                  before kubectl apply or patch
t_generation_visible      object generation visible through kubectl get
t_pod_objects_complete    expected Pod objects exist
t_controller_observed     .status.observedGeneration >= .metadata.generation
t_status_replicas_done    .status.replicas equals expected Pod count, if exposed
t_available_done          Ready/available Pod count equals expected Pod count
```

For Deployment controls, record:

```text
t_submit
t_replicaset_pods_done
t_controller_observed
t_available_done
```

The important split:

- `t_submit -> t_pod_objects_complete`: controller object creation path.
- `t_pod_objects_complete -> t_controller_observed`: informer/status path.
- `t_controller_observed -> t_available_done`: scheduler/image/readiness path.

If ModelServing is slower than Deployment mainly in the first segment, focus on
controller create/reconcile logic. If the difference appears after Pod objects
exist, focus on scheduler/readiness/status propagation.

Minimal timing commands for one ModelServing batch generated by Scenario B,
where each ModelServing creates exactly one Pod:

```bash
export EXPECTED_PODS=100
export START_TS="$(date +%s)"
kubectl apply -f "ms-${EXPECTED_PODS}.yaml"

while true; do
  COUNT="$(kubectl get pod -n "${PERF_NS}" -l modelserving.volcano.sh/group-name --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${COUNT}" = "${EXPECTED_PODS}" ]; then
    POD_OBJECTS_TS="$(date +%s)"
    break
  fi
  sleep 1
done

while true; do
  OBSERVED_COUNT="$(kubectl get modelservings -n "${PERF_NS}" \
    -o jsonpath='{range .items[*]}{.metadata.generation}{" "}{.status.observedGeneration}{"\n"}{end}' 2>/dev/null \
    | awk '$1 == $2 { c++ } END { print c + 0 }')"
  if [ "${OBSERVED_COUNT}" = "${EXPECTED_PODS}" ]; then
    OBSERVED_TS="$(date +%s)"
    break
  fi
  sleep 1
done

READY_TS=""
while true; do
  AVAILABLE_COUNT="$(kubectl get modelservings -n "${PERF_NS}" \
    -o jsonpath='{range .items[*]}{.status.availableReplicas}{"\n"}{end}' 2>/dev/null \
    | awk '$1 == 1 { c++ } END { print c + 0 }')"
  if [ "${AVAILABLE_COUNT}" = "${EXPECTED_PODS}" ]; then
    READY_TS="$(date +%s)"
    break
  fi
  sleep 2
done

echo "pod_objects_seconds=$((POD_OBJECTS_TS - START_TS))"
echo "observed_seconds=$((OBSERVED_TS - START_TS))"
echo "available_seconds=$((READY_TS - START_TS))"
```

Minimal timing commands for the Deployment control:

```bash
export EXPECTED_PODS=100
export START_TS="$(date +%s)"
kubectl apply -f "deploy-${EXPECTED_PODS}.yaml"

while true; do
  COUNT="$(kubectl get pod -n "${PERF_NS}" -l app=kthena-perf-deploy-control --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [ "${COUNT}" = "${EXPECTED_PODS}" ]; then
    POD_OBJECTS_TS="$(date +%s)"
    break
  fi
  sleep 1
done

while true; do
  OBSERVED="$(kubectl get deploy -n "${PERF_NS}" kthena-perf-deploy-control -o jsonpath='{.status.observedGeneration}' 2>/dev/null)"
  GENERATION="$(kubectl get deploy -n "${PERF_NS}" kthena-perf-deploy-control -o jsonpath='{.metadata.generation}' 2>/dev/null)"
  AVAILABLE="$(kubectl get deploy -n "${PERF_NS}" kthena-perf-deploy-control -o jsonpath='{.status.availableReplicas}' 2>/dev/null)"
  if [ -z "${OBSERVED_TS:-}" ] && [ "${OBSERVED}" = "${GENERATION}" ]; then
    OBSERVED_TS="$(date +%s)"
  fi
  if [ "${OBSERVED}" = "${GENERATION}" ] && [ "${AVAILABLE:-0}" = "${EXPECTED_PODS}" ]; then
    READY_TS="$(date +%s)"
    break
  fi
  sleep 2
done

echo "pod_objects_seconds=$((POD_OBJECTS_TS - START_TS))"
echo "observed_seconds=$((OBSERVED_TS - START_TS))"
echo "available_seconds=$((READY_TS - START_TS))"
```

## 4. Scenario A: Idle Baseline

Run this before creating any perf workload:

```bash
kubectl get pod -n "${KTHENA_NS}" "${CM_POD}" -o jsonpath='{.status.containerStatuses[0].restartCount}{"\n"}'
kubectl top pod -n "${KTHENA_NS}" "${CM_POD}" --containers || true
```

Prometheus range: collect 10 minutes.

Record:

- CPU p50/p95/max.
- memory working set p50/max.
- restart count.
- current controller args:

```bash
kubectl get deploy -n "${KTHENA_NS}" kthena-controller-manager \
  -o jsonpath='{.spec.template.spec.containers[0].args}{"\n"}'
```

## 5. Scenario B: ModelServing Count Scale

Purpose: isolate per-ModelServing cache/reconcile/status overhead.

Shape:

```text
N ModelServings
1 top-level replica each
1 role
1 role replica
0 worker replicas, if your schema/admission permits it
otherwise 1 worker replica and account for 2 Pods per ModelServing
```

Recommended points:

```text
10, 50, 100, 250, 500
```

Generate a pure object-scale ModelServing set with one Pod per ModelServing:

```bash
export N=100
cat > "ms-${N}.yaml" <<EOF
EOF

for i in $(seq 1 "${N}"); do
  cat >> "ms-${N}.yaml" <<EOF
---
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: ModelServing
metadata:
  name: perf-ms-${i}
  namespace: ${PERF_NS}
spec:
  schedulerName: volcano
  replicas: 1
  template:
    roles:
      - name: bench
        replicas: 1
        workerReplicas: 0
        entryTemplate:
          spec:
            containers:
              - name: sleep
                image: busybox:1.36
                command: ["sh", "-c", "sleep 3600"]
                resources:
                  requests:
                    cpu: 1m
                    memory: 16Mi
EOF
done
```

Run each point independently:

```bash
kubectl delete ns "${PERF_NS}" --ignore-not-found
kubectl create ns "${PERF_NS}"

# Apply generated ModelServing manifests for this point.
kubectl apply -n "${PERF_NS}" -f ms-${N}.yaml

# Wait for Pod objects, then wait for readiness if the images and scheduler allow it.
kubectl get pod -n "${PERF_NS}" -l modelserving.volcano.sh/group-name --watch
```

Prometheus collection window:

```text
start = 2 minutes before apply
end   = 10 minutes after convergence
```

Collect after convergence:

```bash
kubectl get modelservings -n "${PERF_NS}" -o wide
kubectl get pods -n "${PERF_NS}" -l modelserving.volcano.sh/group-name --no-headers | wc -l
kubectl get podgroups -A | grep "${PERF_NS}" | wc -l
kubectl get events -n "${PERF_NS}" --sort-by=.metadata.creationTimestamp | tail -100
```

## 6. Scenario C: Pod Count Scale

Purpose: distinguish many small ModelServings from few large ModelServings.

Run these shapes at equal Pod count:

```text
100 x 1
10 x 10
1 x 100

500 x 1
50 x 10
10 x 50
1 x 500
```

For each point, run the Deployment control immediately after the ModelServing
case in the same namespace or a fresh namespace with the same node capacity.

Deployment control:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kthena-perf-deploy-control
spec:
  replicas: REPLACE_WITH_EXPECTED_POD_COUNT
  selector:
    matchLabels:
      app: kthena-perf-deploy-control
  template:
    metadata:
      labels:
        app: kthena-perf-deploy-control
    spec:
      schedulerName: volcano
      containers:
        - name: sleep
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: 1m
              memory: 16Mi
```

Generate the Deployment control manifest:

```bash
export EXPECTED_PODS=500
cat > "deploy-${EXPECTED_PODS}.yaml" <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kthena-perf-deploy-control
  namespace: ${PERF_NS}
spec:
  replicas: ${EXPECTED_PODS}
  selector:
    matchLabels:
      app: kthena-perf-deploy-control
  template:
    metadata:
      labels:
        app: kthena-perf-deploy-control
    spec:
      schedulerName: volcano
      containers:
        - name: sleep
          image: busybox:1.36
          command: ["sh", "-c", "sleep 3600"]
          resources:
            requests:
              cpu: 1m
              memory: 16Mi
EOF
```

For a large single-ModelServing case, set:

```yaml
spec.replicas = EXPECTED_PODS
spec.template.roles[0].replicas = 1
spec.template.roles[0].workerReplicas = 0
```

For many small ModelServings, use the generator in Scenario B and set `N` to the
expected Pod count.

If the Deployment controller should be compared without Volcano, remove
`schedulerName: volcano` from both the ModelServing and Deployment tests only if
the ModelServing admission path permits it. Keep scheduler choice identical
within each comparison.

## 7. Scenario D: Autoscaler Metrics Collection

Purpose: measure CPU and memory added by periodic metrics scraping and parsing.

Start with homogeneous targets:

```text
N AutoscalingPolicyBindings
each binding targets one ModelServing
each target Pod exposes /metrics
metrics payload variants:
  small gauge-only
  mixed counter/gauge/histogram
  large payload with many unrelated metrics
```

Use the repository's existing CRD shape:

```yaml
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: AutoscalingPolicy
metadata:
  name: perf-policy
spec:
  tolerancePercent: 50
  metrics:
    - metricName: sglang:token_usage
      targetValue: "1000000000000000"
  behavior:
    scaleDown:
      period: 5s
      stabilizationWindow: 0s
      instances: 10
      percent: 100
      selectPolicy: Or
    scaleUp:
      stablePolicy:
        period: 5s
        stabilizationWindow: 0s
        instances: 10
        percent: 100
        selectPolicy: Or
      panicPolicy:
        period: 1s
        percent: 1000
        panicThresholdPercent: 200
        panicModeHold: 0s
---
apiVersion: workload.serving.volcano.sh/v1alpha1
kind: AutoscalingPolicyBinding
metadata:
  name: perf-binding
spec:
  policyRef:
    name: perf-policy
  homogeneousTarget:
    minReplicas: 1
    maxReplicas: 5
    target:
      targetRef:
        kind: ModelServing
        name: REPLACE_MODEL_SERVING_NAME
      metricEndpoint:
        port: 30000
        uri: /metrics
```

For Autoscaler runs, Pods must be Ready and have reachable Pod IPs. A Pending Pod
set is useful for pure object-scale testing, but not for metrics collection.

Prometheus signs of Autoscaler bottleneck:

- controller CPU has periodic spikes matching the Autoscaler loop.
- API server request rate rises on `modelservings` updates or Pod lists.
- controller logs contain repeated metric fetch or parse errors.
- CPU grows with `bindings * podsPerBinding * metricsPayloadSize`.

Collect controller logs around each metrics cycle:

```bash
kubectl logs -n "${KTHENA_NS}" "${CM_POD}" --since=20m > controller-${SCENARIO}.log
```

## 8. Bottleneck Classification

Use the table below after each run.

```text
Observation:
  ModelServing t_pod_objects_complete much slower than Deployment.
Likely bottleneck:
  Kthena reconcile create path: PodGroup creation, sequential Pod creation,
  role template hashing, plugin hooks, datastore writes, events.
Next evidence:
  apiserver CREATE pod/podgroup latency, controller CPU, controller logs.

Observation:
  Pod objects created quickly, but observedGeneration/status lags.
Likely bottleneck:
  informer cache lag, status update conflicts, workqueue retries, datastore sync.
Next evidence:
  apiserver WATCH/LIST latency, status update request rate/errors, logs.

Observation:
  ModelServing and Deployment Pod objects appear similarly, but Ready/available
  lags only for ModelServing.
Likely bottleneck:
  schedulerName, PodGroup gang scheduling, image pull, readiness behavior.
Next evidence:
  Pod events, PodGroup status, scheduler logs.

Observation:
  CPU baseline is fine, but Autoscaler causes periodic spikes.
Likely bottleneck:
  synchronous Pod metrics scraping and Prometheus text parsing.
Next evidence:
  vary payload size and binding count independently.

Observation:
  memory grows linearly with object count and does not fall after cleanup.
Likely bottleneck:
  informer cache retention, in-memory ModelServing store, Autoscaler scaler or
  optimizer state, histogram windows.
Next evidence:
  compare post-cleanup memory after 5, 10, and 30 minutes.
```

## 9. Data Sheet Template

Record one row per scenario point:

```text
scenario
timestamp_start
timestamp_end
controller_args
controller_restarts_before
controller_restarts_after
modelserving_count
expected_pod_count
actual_pod_count
autoscaling_policy_count
autoscaling_binding_count
metrics_payload
deployment_control_pod_count
ms_t_submit_to_pod_objects_complete_seconds
ms_t_submit_to_observed_seconds
ms_t_submit_to_available_seconds
deploy_t_submit_to_pod_objects_complete_seconds
deploy_t_submit_to_observed_seconds
deploy_t_submit_to_available_seconds
controller_cpu_p95_cores
controller_cpu_max_cores
controller_memory_p95_bytes
controller_memory_max_bytes
apiserver_write_p99_seconds
notes
```

## 10. Cleanup

Always delete the perf namespace and verify no PodGroups remain:

```bash
kubectl delete ns "${PERF_NS}" --ignore-not-found
kubectl get podgroups -A | grep "${PERF_NS}" || true
kubectl get pod -n "${KTHENA_NS}" -l app.kubernetes.io/component=kthena-controller-manager -o wide
```

After cleanup, keep collecting controller CPU/memory for at least 10 minutes. A
healthy baseline should drop near the pre-test idle level, except for informer
cache memory that Go may not return to the OS immediately.

## 11. When to Add Code Instrumentation

Only add temporary code instrumentation after the external timing and Prometheus
data show that the slow phase is inside Kthena reconciliation.

Prioritize timers around:

- `syncServingGroupReplicas`
- `scaleUpServingGroups`
- `CreatePodsForServingGroup`
- `CreatePodsByRole`
- `syncRoleWithinServingGroups`
- `syncHeadlessServices`
- `UpdateModelServingStatus`

Expected output should include namespace/name/generation, expected Pod count,
actual created Pod count, duration, and error. Avoid logging one line per Pod at
large scale unless the test point is small.
