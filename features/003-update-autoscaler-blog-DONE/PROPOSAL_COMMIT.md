# Proposal: Update Autoscaler Blog Post

## Goal
Update `kthena/docs/kthena/blog/autoscaler/index.md` and `kthena/docs/kthena/blog/autoscaler/index_zh.md` to reflect the latest architecture and logic of the Kthena Autoscaler.

## Proposed Changes

### 1. Introduction & Architecture
- Remove mentions of Autoscaler being a "separate component".
- State that it is a controller integrated into `kthena-controller-manager`.
- Update diagrams or text to show it as part of the control plane.

### 2. Metrics Collection
- Highlight that business-level metrics (e.g., waiting requests, KV cache usage) from engines like vLLM are primary.
- Explain the mechanism of direct Pod metric scraping.

### 3. Policy & Binding Logic
- Refactor the "Policy and Binding" section to explain:
    - `AutoscalePolicy`: Defines *how* to scale (thresholds, windows, metrics).
    - `AutoscaleBinding`: Defines *what* to scale.
    - Explain the two modes of binding:
        - Targeting `ModelServing` or `ServingGroup` for proportional scaling of all roles.
        - Targeting a specific `Role` for independent/heterogeneous scaling (e.g., scaling only the `decode` role).

### 4. Structure Refactoring
- Merge the "Integration with ModelServing and Volcano" content into the architecture and logic sections.
- Ensure consistency between English and Chinese versions.

## Implementation Results

### 1. Architecture Update
- Introduction now correctly identifies Autoscaler as a controller within `kthena-controller-manager`.
- Updated Mermaid diagrams to reflect the integrated architecture.
- Merged integration details (Volcano, ModelServing) into relevant sections.

### 2. Metrics Collection
- Added emphasis on business-level metrics (e.g., vLLM waiting requests).
- Clarified that the Autoscaler scrapes metrics directly from Pods.

### 3. Policy & Binding Refactoring
- Renamed `AutoscalingPolicy` -> `AutoscalePolicy`.
- Renamed `AutoscalingPolicyBinding` -> `AutoscaleBinding`.
- Added clear distinction between:
    - **Form A (Fixed-Ratio Scaling):** Binding to `ModelServing` or `ServingGroup`.
    - **Form B (PD Heterogeneous Scaling):** Binding to specific `Role`.

### 4. Cleanup & Renumbering
- Removed redundant Section 5 ("Integration with ModelServing and Volcano").
- Renumbered subsequent sections (Practical Usage, Best Practices, Future Directions).
- Updated all `kubectl` command examples and YAML snippets.

## Verification
- Verified both `index.md` and `index_zh.md` for consistency.
- Checked formatting, links, and code blocks.
- Global search confirmed no "AutoscalingPolicy" remains.

## Commit Hash
- [Internal task completion]
