# Workflow concurrency and static matrices

This adds server-side scheduling for the two contracts used by openseek's Editor
workflow. The original `editor.yml` at openseek commit
`9e8b15a59b40b62b018e53b4b85a3bea971e1acf` is retained verbatim under
`pipeline/workflow/fixtures/`. It parses into two `moon-gates` instances and the
independent browser-correctness job, with the original workflow concurrency.

## Workflow concurrency

Workflow-level `concurrency` accepts a string group or a mapping with `group`
and `cancel-in-progress`. The latter is a boolean or a boolean expression;
omission defaults to false. Groups are case-insensitive and repository-scoped,
including when multiple workflow files intentionally use the same group.

The coordinator saves group admission in `pipeline_run_schedule` within the
snapshot transaction. Each group has one admitted run and at most one pending
run. New arrivals cancel and replace the previous pending run. With
`cancel-in-progress: true`, the admitted run is cancelled too. Its slot remains
occupied until active attempts complete or their leases expire, so a replacement
cannot overlap an execution still being fenced. With false, the admitted run is
allowed to finish. Pending work is admitted transactionally on the next claim.
No ownership or pending state is kept only in process memory.

Groups may use captured `github.workflow`, `github.ref`, `github.repository`,
`github.sha`, `github.event_name`, `github.head_ref`, `github.base_ref` and
`github.run_id`. For an MR, `github.ref` is `refs/pull/NUMBER/merge`, so two MRs
using the same source branch have different refs. Push/manual refs are the saved
`refs/heads/BRANCH`. Workflow concurrency supports only the github context;
secrets, environment and matrix contexts are rejected, even in an unevaluated
boolean branch. A group is resolved once per saved run, not from later refs.

The bounded scheduling expression parser supports scalar literals, field and
literal-string indexes, `!`, `==`, `!=`, `&&`, `||`, parentheses, `contains`,
`startsWith`, `endsWith` and `format`. Context/function identifiers ignore case,
string comparisons ignore case, and booleans short-circuit. Templates interpolate
once; values containing expression markers are not evaluated recursively.
Unsupported functions/syntax fail explicitly. Group results require 1-256 UTF-8
bytes. Job-level concurrency and dispatch-input/vars contexts are not supported.

## Static matrices

A strategy requires a literal `matrix` mapping. Axis lists form a Cartesian
product in YAML order. Values are scalar strings, numbers, booleans or null;
object axes and dynamic `fromJSON` matrices remain rejected. Includes and excludes
are lists of scalar mappings. Excludes remove combinations matching all supplied
axis fields. Each include merges into compatible original combinations without
overwriting an original axis; an incompatible include adds a standalone job.
Subsequent includes do not merge into standalone included jobs.

Matrix jobs receive deterministic internal keys such as `build[1]`. Their public
`github.job` / `GITHUB_JOB` remains the logical key `build`. The snapshot and wire
assignment retain typed `matrix` and `strategy` contexts, including job-index,
job-total, fail-fast and max-parallel. Step run/env/with/condition templates use
the runtime interpreter; job `name`, `runs-on` and step display names can use the
matrix/strategy scheduling contexts. Executable text is not rewritten recursively.

`strategy.max-parallel` is an integer from 1 to 256; omission permits the bounded
matrix to use available providers. The claim transaction counts leased/running
siblings, so simultaneous providers cannot exceed the cap. A cancellation retains
its slot until that attempt ends. `strategy.fail-fast` is a literal boolean,
default true. A failed, timed-out or lost instance cancels queued and running
siblings in that matrix only. False allows other instances to continue. Failure
is retained in the overall result rather than being hidden by sibling cancellation.
Explicit run cancellation still produces a cancelled run.

A downstream `needs: build` expands to every instance. It waits until the entire
matrix finishes; if any instance failed/cancelled/skipped, the ordinary dependent
job is skipped. Cycles and unknown logical dependencies remain rejected. Job-level
if/continue-on-error, needs outputs and experimental matrix policy are separate
features and are not silently accepted.

Limits are 16 logical jobs, 16 axes, 256 combinations per matrix, 256 expanded
jobs per workflow, 4096 expanded steps and a 1-MiB normalized snapshot.
Template/format results are charged in UTF-8 bytes before appending, and matrix
instances consume remaining job/step/plan budgets while they are constructed. The queue
page distinguishes dependency, concurrency-group and matrix-capacity waits.

## Upgrade and acceptance boundary

Migration 031 adds concurrency admissions and matrix scheduling columns. Existing
runs are left independent, with no group, a 256 parallel default and fail-fast
disabled. Definition versions 1 and 2 remain readable and reruns preserve their
saved version. New snapshots use definition version 3 and assignment version 6.
Old providers/runners reject V6 instead of executing missing matrix contexts.
Upgrade coordinator, provider and runner together; downgrade to schema 30 is not
supported. No existing runs are replayed by the migration.

The scheduler is independent of runner OS. `macos-latest`, `macos-14` and
`macos-15` selectors request exact `self-hosted,macos,arm64,ENVIRONMENT` capabilities.
They do not route to a generic Linux machine or assert an entire GitHub software
inventory. Actual macOS execution depends on the separate prepared-VM backend
and an explicitly configured matching image. This change validates the original
Editor plan and scheduler contracts, not a claim that its browser suite was run
on a production macOS VM. Full Editor acceptance must include that environment's
fonts, Homebrew/just, Playwright and browser geometry expectations.

Regression coverage includes original Editor parsing, typed include/exclude,
nonrecursive expressions, persistent group admission, pending replacement,
cancellation fencing, distinct MR refs, multi-provider parallel caps, failure
propagation, dependent-job aggregation, native V6 context delivery, schema-30
upgrade/idempotence and legacy snapshots.

The existing opt-in native HTTP smoke can also run the unchanged Linux matrix
instance directly from the original Editor YAML:

```sh
docker build --platform linux/amd64 -f deploy/ubuntu/Dockerfile \
  --target tools-sdk-check -t moonhub-scheduling:check .
docker run --rm --platform linux/amd64 \
  --mount type=bind,src="$PWD",dst=/work,readonly \
  --mount type=bind,src=/tmp/openseek.git,dst=/source.git,readonly \
  moonhub-scheduling:check /source.git editor-linux
```

Prepare `/tmp/openseek.git` at the fixed commit as described in
[workflow-entry acceptance](workflow-entry.md#acceptance). This smoke uses a V6
assignment with the Linux matrix and typed strategy context, while preserving
all original step contents, scalar inputs and defaults. It complements the
server's original-YAML expansion and transactional scheduling tests; it does not
substitute for full Linux/macOS/Browser acceptance.

Observed local Linux acceptance on November 5, 2026: checkout v6, the original
pinned MoonBit install, dependency update, all-target check and format succeeded
through V6. The final unmodified `moon test --target all` failed with multiple
link workers reporting `Killed` in the local emulated x64 container. The native
runner reported failure and executed checkout post cleanup. This is deliberately
not recorded as a passing full Editor acceptance; rerun on an appropriately
provisioned native x64 worker and complete macOS/browser acceptance before claiming
that migration gate. No upstream test steps or compiler optimization mode were
changed to manufacture a passing result.
