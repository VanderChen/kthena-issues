# Kthena Issues and Lab Artifacts

This repository tracks Kthena bugs, feature proposals, reproduction assets,
performance runbooks, benchmark scripts, and verification results.

The product source repository is kept separate. Each issue should record the
source commit, image tag, Helm values, cluster shape, and verification output
used for the work.

## Layout

```text
bugs/
  [ID]-[title]-[STATUS]/
features/
  [ID]-[title]-[STATUS]/
```

`STATUS` is one of:

- `OPEN`
- `IP`
- `DONE`

Each task directory should include:

- `DESCRIPTION.md`: problem statement or feature request.
- `PROPOSAL_COMMIT.md`: analysis, proposal, verification plan, implementation
  commits, and final results.

Task-specific scripts, manifests, and results should live inside the task
directory:

```text
scripts/
manifests/
results/
```

## Source References

Prefer recording immutable source references in each result:

```text
kthena_commit:
kthena_branch:
controller_manager_image:
helm_chart_version_or_commit:
helm_values:
cluster:
```

If a local checkout is needed, pass it explicitly to scripts:

```bash
export KTHENA_REPO=/path/to/kthena
```

Using a Git submodule for `kthena/` is optional. Do it only when scripts need to
read or build the source tree directly.
