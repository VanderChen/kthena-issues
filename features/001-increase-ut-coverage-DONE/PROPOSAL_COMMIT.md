# Proposal: Increase Unit Test Coverage

## Problem Statement
The current unit test coverage for some utility and handler packages in the `kthena/` codebase is 0%. This increases the risk of regressions and makes it harder to maintain the code.

## Proposed Changes
I propose adding unit tests for the following packages:
1.  **`pkg/kthena-router/utils`**: Test utility functions like `GetNamespaceName`, `ParsePrompt`, `GetPromptString`, and `LoadEnv`.
2.  **`pkg/kthena-router/handlers`**: Test request and response parsing logic, specifically `ParseOpenAIRequestBody`, `ParseOpenAIResponseBody`, and `ParseStreamRespForUsage`.
3.  **`pkg/model-booster-controller/utils`**: Test common utility functions and template replacement logic, including `TryGetField`, `GetDeviceNum`, `ReplaceEmbeddedPlaceholders`, `ConvertVLLMArgsFromJson`, and `ReplacePlaceholders`.
4.  **`pkg/kthena-router/backend/vllm`**: Test vLLM backend logic like `GetPodModels`.

## Implementation Plan
1.  Create `pkg/kthena-router/utils/utils_test.go` and implement tests.
2.  Create `pkg/kthena-router/handlers/request_test.go` and implement tests.
3.  Create `pkg/kthena-router/handlers/response_test.go` and implement tests.
4.  Create `pkg/model-booster-controller/utils/common_test.go` and implement tests.
5.  Create `pkg/model-booster-controller/utils/template_test.go` and implement tests.
6.  Create `pkg/kthena-router/backend/vllm/models_test.go` and implement tests.

## Results
I have added unit tests for the following packages, resulting in a total of over 800 lines of new test code.

1.  **`pkg/kthena-router/utils`**: Added `utils_test.go`. Coverage: 68.1%.
2.  **`pkg/kthena-router/handlers`**: Added `request_test.go` and `response_test.go`. Coverage: 95.8%.
3.  **`pkg/model-booster-controller/utils`**: Added `common_test.go` and `template_test.go`. Coverage: 83.8%.
4.  **`pkg/kthena-router/backend/vllm`**: Added `vllm_test.go`. Coverage: 85.1%.
5.  **`pkg/kthena-router/webhook`**: Added `utils_test.go`. Coverage: 44.4%.

Total lines added (tests): ~950 lines.

## Verification
- Ran `go test -cover ./pkg/kthena-router/utils ./pkg/kthena-router/handlers ./pkg/model-booster-controller/utils ./pkg/kthena-router/backend/vllm ./pkg/kthena-router/webhook`.
- All tests passed.
- Coverage for these packages increased significantly.
- Ran `make lint` and `go fmt ./...`.
- Final unit tests pass across the codebase (except for some environment-specific issues already present).
