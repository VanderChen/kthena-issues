# Bug 008: Manual replica shrink then immediate grow may miss Pods

## Status

IP

## Problem

Validate whether manually changing `ModelServing.spec.replicas` to shrink a
workload and then immediately growing it again can leave expected Pods missing.

This scenario is not driven by Autoscaler or KEDA; it uses direct user updates
to `spec.replicas`.

## Expected Behavior

After the final manual update sets `spec.replicas` back to the larger value, the
controller should eventually create all expected ServingGroup role Pods.

