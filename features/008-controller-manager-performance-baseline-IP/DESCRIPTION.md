# Feature 008: kthena-controller-manager performance baseline

## Status

IP

## Goal

Establish a deployment performance baseline for `kthena-controller-manager`.

Evaluation dimensions:

- Number of managed Pods.
- Number of managed ModelServings.
- Autoscaler runtime metrics collection scenarios.
- `kthena-controller-manager` CPU and memory usage under steady state and
  reconcile churn.

## Scope

Read source code to identify likely bottlenecks, then design repeatable Kind
performance test scenarios and measurement methods.

Initial work is proposal and test design only. Do not change implementation code
until the plan is reviewed and approved.

