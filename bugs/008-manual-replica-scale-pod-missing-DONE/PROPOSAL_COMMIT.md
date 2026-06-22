# Verification: Manual replica shrink then immediate grow

## Scope

Kind validation only. No implementation changes.

## Kind Verification Results

### Environment

- Date: 2026-06-22
- Context: `kind-kind`
- Controller-manager image:
  `kthena-controller-manager:dev-007-same-name-fix-v2`
- Controller-manager flags included:
  `--enable-eviction-webhook=true`, `--eviction-tracker-ttl=60s`
- Test namespace: `replica-flap-008`
- ModelServing: `manual-replica-flap`
- Initial/final manual `spec.replicas`: `5`
- Shrink target: `1`
- Roles per ServingGroup: `prefill`, `decode`
- Expected final Pods after grow: `10`

Volcano scheduler was not healthy during this run because the scheduler Pod was
re-pulling `docker.io/volcanosh/vc-scheduler:v1.13.1` and Docker Hub requests
timed out. New test Pods therefore remained `Pending`. The validation was scoped
to whether the controller creates the expected Pod objects, not whether the Pods
become scheduled or Ready.

### Reproduction Artifacts

```text
issues/bugs/008-manual-replica-scale-pod-missing-DONE/reproduce-kind-manual-replica-flap.yaml
issues/bugs/008-manual-replica-scale-pod-missing-DONE/reproduce-manual-replica-flap.sh
```

The script manually patches `ModelServing.spec.replicas` from `5` to `1` and
back to `5`, without Autoscaler or KEDA. It waits for the controller to observe
the final generation and then requires the expected Pod names to exist for
multiple consecutive reads.

Command:

```bash
ITERATIONS=20 SETTLE_SECONDS=60 \
  bash issues/bugs/008-manual-replica-scale-pod-missing-DONE/reproduce-manual-replica-flap.sh
```

The run covered 100 shrink/grow operations:

```text
20 iterations x delays 0, 0.1, 0.3, 0.7, 1.5 seconds
```

Result:

```text
PASS: 20 iterations across delays (0 0.1 0.3 0.7 1.5) maintained expected pod objects
spec=5 status=5/ observedGeneration=205 generation=205
```

Final Pods:

```text
manual-replica-flap-0-decode-0-0
manual-replica-flap-0-prefill-0-0
manual-replica-flap-1-decode-0-0
manual-replica-flap-1-prefill-0-0
manual-replica-flap-2-decode-0-0
manual-replica-flap-2-prefill-0-0
manual-replica-flap-3-decode-0-0
manual-replica-flap-3-prefill-0-0
manual-replica-flap-4-decode-0-0
manual-replica-flap-4-prefill-0-0
```

Final PodGroups:

```text
manual-replica-flap-0
manual-replica-flap-1
manual-replica-flap-2
manual-replica-flap-3
manual-replica-flap-4
```

### Observations

An earlier version of the script checked Pod names too early, before
`status.observedGeneration` caught up to the final object generation. That
showed a transient window where group 4 Pods were absent after the grow patch,
but the controller created them a few seconds later.

Controller logs during the final run also showed short-lived reconcile races:

```text
failed to set role manual-replica-flap-3/prefill-0 status: serving group not found
manageRoleReplicas: role decode/decode-0 in ServingGroup manual-replica-flap-4 is missing pods (0/1), recreating
```

Despite those transient logs, the controller converged in this run: after the
final generation was observed, all 10 expected Pod objects and all 5 PodGroups
were present.

### Conclusion

This Kind run did not reproduce a persistent Pod-missing bug for manual
`spec.replicas` shrink followed immediately by grow. It did confirm transient
deletion/recreation windows and at least one noisy controller error during
rapid scale changes. Because the scheduler was unhealthy, this result only
proves object creation convergence, not readiness convergence.
