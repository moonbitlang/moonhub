# Job outputs, needs and conditions

Definition version 4 adds job dataflow to the downloaded Actions runtime. The
runner resolves declared job output templates after normal steps and Action post
handlers. Its completion report carries the resulting string map. The coordinator
commits accepted outputs and terminal attempt state together, then evaluates
dependent jobs in the same transaction.

```yaml
on: workflow_dispatch
jobs:
  version:
    runs-on: ubuntu-24.04
    outputs:
      release: ${{ steps.check.outputs.release }}
      version: ${{ steps.check.outputs.version }}
    steps:
      - id: check
        run: |
          echo release=true >> "$GITHUB_OUTPUT"
          echo version=1.2.3 >> "$GITHUB_OUTPUT"
  build:
    needs: version
    if: github.ref == 'refs/heads/main' && needs.version.outputs.release == 'true'
    runs-on: ubuntu-24.04
    env:
      VERSION: ${{ needs.version.outputs.version }}
    steps:
      - run: printf '%s\n' "$VERSION" > version.txt
      - uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
        with:
          name: release-v${{ needs.version.outputs.version }}
          path: version.txt
```

## Context and evaluation

`needs.JOB.outputs.NAME` and `needs.JOB.result` include only direct dependencies,
not every ancestor. Missing outputs resolve to an empty string. Results are
`success`, `failure`, `cancelled` or `skipped`; loss and timeout map to failure.
Steps can consume needs in run, env, with and condition templates, including
inside downloaded JavaScript/composite Actions. Pass untrusted output through
env/with instead of interpolating shell code.

Job `if` accepts a boolean, an expression string or a whole expression wrapper.
It uses captured `github`, typed dispatch `inputs`, repository `vars` and direct
`needs`, scalar literals, field/string-key
indexes, parentheses, `!`, `==`, `!=`, `&&`, `||`, `contains`, `startsWith`,
`endsWith`, `format`, and `success()`, `failure()`, `cancelled()`, `always()`.
Function names and field lookup ignore case; boolean operators short circuit.
Without an explicit status function, the condition has an implicit success guard.
Failed/lost/timed-out/cancelled/skipped ancestors prevent ordinary dependent jobs
from running. Failure checks failed/lost/timed-out ancestors; cancellation checks
cancelled ancestors. Explicit status functions allow cleanup branches.

Conditions run only after all direct dependencies finish. Root conditions are
evaluated when the snapshot is inserted. Every static matrix instance uses the
same condition; matrix/strategy are unavailable in job conditions. False produces
a terminal skipped job without allocating a runner. A data-dependent expression
error fails that job without rolling back upstream completion. Cancelling a
whole run still cancels all queued/waiting jobs, including always jobs.

Output definitions accept scalar templates using `steps`, `needs`, `github`,
`matrix`, `strategy`, `runner`, dispatch `inputs` and repository `vars`. Values become strings.
Secret references, env and unsupported functions fail validation. Values are
evaluated once, without recursively interpreting captured expression markers.
Success/failure reports may publish outputs; cancelled/timed-out/lost attempts do
not.

A matrix dependency waits for every instance and appears under its logical key.
Outputs combine in completion order; the last published non-empty value wins
collisions. Empty values are omitted and do not erase another instance's output.
Use unique names when a deterministic result across concurrent instances matters.
Aggregate results prefer failure, then cancellation, skip and success. Existing
fail-fast and max-parallel policies remain in force.

## Persistence and limits

Migration 035 adds `pipeline_job_output`, linked to both job and attempt. No old
outputs are invented or jobs replayed. Reruns create new storage. Expired leases
and conflicting completion replays cannot overwrite it; identical reports are
idempotent.

At most 100 names are allowed per job. Each value is at most 16 KiB UTF-8, the
encoded map at most 32 KiB, and all stored maps in a run at most 256 KiB. NUL and
undeclared names are rejected. The run budget bounds downstream assignment
contexts; provider responses are limited to 2 MiB, matching the standalone runner.
Oversized reports do not partially publish output or complete an attempt. After
an explicit HTTP 400 for a non-empty output completion, the runner reports failure
without outputs so a full run budget cannot leave an executed job waiting for
lease expiry. Conflicts and uncertain transport results retain the original
completion payload.

The runner omits values containing registered masks, including Action runtime
credentials and post-handler masks. The server independently filters secrets
delivered to that attempt, using log-mask variants. These substring checks do
not guarantee protection against deliberately transformed secrets.

Definition-v4 snapshots use assignment version 7. Dispatch definition-v5 runs use
assignment version 8 for [dispatch inputs](dispatch-inputs.md). Current runs use
definition version 6 and assignment version 9 for repository variables. Old
runners reject unsupported versions. Upgrade coordinator, provider/controller
and runner together. Definition versions 1-5 and their
original assignment versions remain supported, including old completion hashes.
The runner retains the original completion field set for legacy assignments.
Reruns retain their saved definition version.

## Verification and remaining migration work

The reduced `openseek-release-dataflow.yml` fixture derives from desktop-release
at openseek commit `bff9ae35088250ee8077262a8906ae8ca103130b`. It preserves six job
IDs, needs/if/outputs and job environment. Execution is stubbed and the unsupported
windows-latest alias uses explicit self-hosted Windows labels. It does not claim
acceptance of the full release YAML, signing, authenticated APIs or publishing.

The normal native HTTP test executes version preparation, two conditional matrix
builds and a consuming job using the real runner, plus a skipped branch. Enable
upstream acceptance to download and execute pinned upload/download Artifact v4
Actions in that same chain:

```sh
MOONHUB_DATAFLOW_UPSTREAM=1 \
MOONHUB_ARTIFACT_NODE20=/absolute/path/to/node20 \
moon test --strip -j 1 web/views/pipelines \
  --filter '*real runner carries version*'
```

The test defaults its Action Node to the installed Node; provide Node 20 for the
pinned node20 entry points. Production defaults still use the prepared Node 20
runtime. All matrix instances here execute on the local host, not separate
macOS/Windows release machines.

Dynamic matrices, job continue-on-error other than literal `false`, scheduled triggers,
OIDC, write permissions and authenticated release APIs remain separate work. See
[GitHub Actions](github-actions.md), [workflow scheduling](workflow-scheduling.md),
[Artifact v4](artifact-v4.md) and [Cache v4](cache-v4.md).

Repository configuration variables are available in job conditions and outputs
from definition version 6 / assignment version 9; see
[repository variables](repository-variables.md). Values are captured with the run
and snapshot reruns do not reload current repository settings.
