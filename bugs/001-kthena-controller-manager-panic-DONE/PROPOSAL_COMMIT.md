# Bug Fix Proposal & Implementation

## Analysis
The `kthena-controller-manager` panics when creating a `ModelServing` workload with annotations in the `entryPod` or `workerPod` metadata.
The panic occurs in `pkg/model-serving-controller/utils/utils.go` in the `addPodLabelAndAnnotation` function.
When `createBasePod` is called, it initializes the `Labels` map but does not initialize the `Annotations` map in the `Pod` object.
When `addPodLabelAndAnnotation` is later called with metadata that contains annotations, it attempts to assign values to the `pod.Annotations` map, which is `nil`, resulting in a "assignment to entry in nil map" panic.

## Proposed Solution
Modify `addPodLabelAndAnnotation` in `pkg/model-serving-controller/utils/utils.go` to ensure that `pod.Labels` and `pod.Annotations` maps are initialized before assigning values to them if the input metadata contains labels or annotations.

## Implementation Details
- Modified `kthena/pkg/model-serving-controller/utils/utils.go`:
    - Updated `addPodLabelAndAnnotation` to check for `nil` maps and initialize them using `make(map[string]string)` before assignment.
- Updated unit tests in `kthena/pkg/model-serving-controller/utils/utils_test.go`:
    - `TestGenerateEntryPod_WithAnnotations`: Verifies that `GenerateEntryPod` does not panic and correctly handles annotations.
    - `TestGenerateWorkerPod_WithAnnotations`: Verifies that `GenerateWorkerPod` does not panic and correctly handles annotations.

## Verification Results
- Unit Tests:
    - Ran `go test -v ./pkg/model-serving-controller/utils/` and all tests passed, including the new verification tests.
- Kind Verification:
    - Built a Linux/ARM64 binary and a Docker image with fixed entrypoint.
    - Loaded the image into a Kind cluster.
    - Deployed Kthena using `helm upgrade --install` from local charts.
    - Applied a `ModelServing` manifest (`repro_panic.yaml`) with pod annotations.
    - Confirmed `kthena-controller-manager` did not panic and successfully created pods with the specified annotations.

## Associated Commits
- Commit ID: [TBD]
- Branch: fix/001-controller-panic
