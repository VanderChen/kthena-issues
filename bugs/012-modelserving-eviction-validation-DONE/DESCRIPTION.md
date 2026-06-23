# Bug: ModelServing webhook does not fully validate eviction minAvailable

## Summary
The ModelServing validating webhook does not fully validate
`spec.rolloutStrategy.evictionStrategy`.

When eviction protection is configured, the webhook should require an explicit
minimum availability threshold and reject invalid `minAvailable` /
`roleMinAvailable` values before the resource is admitted.

## Steps to Reproduce
1. Create or update a `ModelServing` with
   `spec.rolloutStrategy.evictionStrategy.protectionLevel: ServingGroup` but
   without `minAvailable`.
2. Create or update a `ModelServing` with an invalid eviction threshold, such as
   a negative value, an invalid percent string, a percentage greater than 100,
   or a value that exceeds the applicable replica count.
3. For Role protection, configure `protectionLevel: Role` without
   `roleMinAvailable`, with an empty `roleMinAvailable` map, or with a
   role-specific threshold that exceeds that role's replica count.

## Expected Behavior
- If `evictionStrategy` is configured, a minimum availability threshold must be
  explicitly configured.
- `ServingGroup` protection requires `minAvailable`.
- `Role` protection requires at least one `roleMinAvailable` entry, while still
  allowing partial role protection for the configured role keys.
- All configured min-availability thresholds must be valid integer-or-percent
  values and must not resolve above their applicable total:
  - `minAvailable` <= `spec.replicas`.
  - `roleMinAvailable[role]` <= that role's replicas.
- Invalid resources should be rejected by the ModelServing validating webhook.

## Actual Behavior
Current code in `pkg/model-serving-controller/webhook/validator.go` only checks
some eviction threshold values:

- `ServingGroup` mode validates `minAvailable` only when it is present, so a
  configured eviction strategy can be admitted without an explicit
  `minAvailable`.
- `Role` mode validates `roleMinAvailable` when the map is present, but allows
  a nil or empty map, which means the configured eviction strategy has no
  explicit min threshold.
- Existing validation checks integer-or-percent syntax and unknown role keys,
  but does not reject values that resolve above the applicable replica count.

## Environment Details
- Kthena Version: local `main` as of branch
  `fix/012-modelserving-eviction-validation`.
- Kubernetes Version: not yet verified in Kind.
- OS: local development workspace.
- Relevant Logs/Events: not yet captured; this is currently characterized from
  webhook code and existing unit coverage.
