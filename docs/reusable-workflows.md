# Local reusable workflows

A job can call `./.github/workflows/FILE.yml` or `.yaml`. The file must be a
regular file at the caller's pinned commit and declare `on.workflow_call`.
External repository references, branch/tag suffixes, dynamic paths and directory
traversal are rejected. Selected jobs include their dependency closure before
callee discovery, so selecting `required` from this repository's unchanged
`ci.yml` includes its frontend callee and all six logical dependency checks.

```yaml
on: workflow_dispatch
permissions:
  contents: read
jobs:
  build:
    uses: ./.github/workflows/build-library.yml
    with:
      target: native
      verify: true
  publish:
    needs: build
    runs-on: self-hosted
    steps:
      - run: echo '${{ needs.build.outputs.version }}'
```

The callee declares typed inputs and outputs:

```yaml
on:
  workflow_call:
    inputs:
      target: {type: string, default: native}
      verify: {type: boolean, required: true}
    outputs:
      version:
        value: ${{ jobs.compile.outputs.version }}
jobs:
  compile:
    runs-on: self-hosted
    outputs:
      version: ${{ steps.version.outputs.value }}
    steps:
      - id: version
        run: echo 'value=1.2.3' >> "$GITHUB_OUTPUT"
```

Input types are `string`, `number` and `boolean`. Declarations require a type;
defaults and supplied values must match it. Expressions in `with` resolve after
caller dependencies complete, using captured `github`, `inputs`, `vars` and direct
`needs`. Callee `inputs` are separate from the caller's saved event inputs.
Undeclared or missing required inputs fail explicitly. Caller environment values
are not implicitly inherited; each callee owns its workflow/job/step environment.

Callee jobs run under the caller's repository authority. Their contents, job API
and OIDC permissions are intersected with the caller job's permissions at every
nested call. Repository secret policies continue to use the original branch and
workflow identity and are rechecked when expanded jobs are admitted and when
values are delivered. Call inputs and outputs cannot reference the secrets context.

The caller waits for the callee's jobs and publishes declared outputs through
`needs.CALLER.outputs`. A failed callee fails the caller aggregate; ordinary
external dependents are then skipped. Internal `needs` and matrix contexts retain
local job names. Stored keys are namespaced, for example `frontend/browser`, so
repeated and nested calls cannot overwrite another call's results. Static and
dynamic matrices inside a callee use the existing scheduling and failure policies.

Workflow-level concurrency declared by a callee uses its resolved inputs and is
held by the caller aggregate. A caller and its callee cannot both declare
concurrency; use distinct child-job groups when both scopes need serialization.
Cancellation retains aggregate admission until all active callee workers have
acknowledged cancellation or lost their leases. Unrelated caller jobs remain
eligible. Job-level `uses` currently accepts `name`, `needs`, `if`, `with`,
`permissions` and `concurrency`; caller-level matrices and secret forwarding are
outside this local-call contract.

Schema 52 stores call expansion inputs and aggregate outputs separately from the
original run definition. The definition retains the complete normalized callee
and original callee source. Restart and duplicate completion reuse these records.
A snapshot rerun never reloads a moved source branch. Failed-only reruns reuse
unaffected call aggregates or children, including saved outputs and historical
log/artifact links. Aggregate output masking uses bounded secret fingerprints
captured before child credential cleanup, including earlier attempts in the same
run family. Raw credentials are still deleted at completion. More than 4096
fingerprints, or excessive substring hashing work, suppresses affected outputs.

Cycles are rejected, nesting is limited to ten calls, and source discovery to
64 files and 1 MiB. Nested executable jobs and steps share the workflow's 256-job,
4096-step and 1-MiB normalized snapshot budgets; runtime expansion charges its
additional stored definitions too. Output limits remain 100 values, 16 KiB per
value, 32 KiB per producer and 256 KiB per run. Existing assignment protocols
already carry the necessary inputs, matrix and output contexts; no runner
protocol extension is needed for server-side calls.

Tests validate unchanged `ci.yml` selection and the original frontend source,
plus local execution fixtures for pinning, typed inputs, outputs, nesting,
permission ceilings, dynamic matrices, failed-only reuse and cancellation.
These fixtures do not execute all production CI scripts on Linux, Windows and
macOS, and do not run the production deployment workflow.
