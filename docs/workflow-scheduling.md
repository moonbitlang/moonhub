# Workflow and job scheduling

This adds server-side scheduling for the two contracts used by openseek's Editor
workflow. The original `editor.yml` at openseek commit
`9e8b15a59b40b62b018e53b4b85a3bea971e1acf` is retained verbatim under
`pipeline/workflow/fixtures/`. It parses into two `moon-gates` instances and the
independent browser-correctness job, with the original workflow concurrency.

## Workflow concurrency

Workflow-level and job-level `concurrency` accept a string group or a mapping
with `group`, `cancel-in-progress` and optional `queue: max`. The latter is a boolean or a boolean expression;
omission defaults to false. Groups are case-insensitive and repository-scoped,
including when multiple workflow files intentionally use the same group.

The coordinator saves admission in `pipeline_concurrency_slot`; the historical
`pipeline_run_schedule` query is preserved as a view. Workflow admission happens
in the snapshot transaction; job admission happens after its dependencies and
condition pass, and after its workflow is admitted. Each group has one admitted run and at most one pending
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
`refs/heads/BRANCH`. Current snapshots also expose captured `github.event` and
typed workflow `inputs` and repository `vars`; see [dispatch inputs](dispatch-inputs.md)
and [repository variables](repository-variables.md). Secrets,
environment and matrix contexts are rejected, even in an unevaluated boolean
branch. A group is resolved once per saved run, not from later refs.

The bounded scheduling expression parser supports scalar literals, field and
literal-string indexes, `!`, `==`, `!=`, `&&`, `||`, parentheses, `contains`,
`startsWith`, `endsWith` and `format`. Context/function identifiers ignore case,
string comparisons ignore case, and booleans short-circuit. Templates interpolate
once; values containing expression markers are not evaluated recursively.
Unsupported functions/syntax fail explicitly. Group results require 1-256 UTF-8
bytes. Job groups additionally accept direct `needs`, `matrix` and `strategy`
contexts. Workflow and job groups share the repository namespace. A job using its
own workflow's group fails with a diagnostic instead of waiting for itself.

`queue: max` preserves up to 100 pending entries in FIFO admission order. The
101st waiter is cancelled without displacing existing work. It cannot be combined
with `cancel-in-progress` other than literal false. The default remains one pending
entry with replacement. Both modes retain a cancelled holder until execution is
fenced; leases and restart recovery use the same durable admission records.

## Static matrices

A static strategy uses a literal `matrix` mapping. Axis lists form a Cartesian
product in YAML order. Axis values can be strings, numbers, booleans, null or
objects containing other literal values. For example, an axis named `node`
with an entry `{version: 20}` exposes `matrix.node.version` for that job.
Arrays nested in an object support zero-based literal string indexes such as
`matrix.node.labels['0']` in `runs-on`, job names and step display names. Use
`'0'` or a positive decimal integer without leading zeros. Invalid and
out-of-range indexes interpolate as empty strings.
Includes and excludes also accept objects and nested arrays as values. Excludes remove combinations
matching all supplied axis fields by value. Each matching include adds or updates
extra fields on compatible original combinations. Original axis objects keep
their YAML field order, so case-insensitive lookup still uses the first matching
field. An incompatible include adds a standalone job. Only the original
combinations are eligible for later includes.

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
conditions and outputs are described in [job dataflow](job-dataflow.md).
Job-level `continue-on-error` accepts a boolean or an expression using direct
`needs`, `matrix`, `strategy`, captured `github`, `inputs` and `vars`. It resolves
once before admission. A true policy records an actual `failure` and an effective
`success`. Dependencies, fail-fast and run aggregation use the effective result;
worker attempts, logs and the run page retain the failure. Timeouts, lost workers
and cancellation are not converted to success. Failed-only reruns can rerun an
allowed failure too.

## Dynamic matrices

A complete expression such as
`strategy.matrix: ${{ fromJSON(needs.prepare.outputs.matrix) }}` defers expansion
until dependencies complete and the job condition passes. The expression may use
`needs`, captured `github`, typed `inputs` and saved `vars`. It must produce a
matrix mapping with the same axes/include/exclude rules as a static matrix.
JSON input is limited to 64 KiB, 32 levels and 8192 nodes. Empty matrices, malformed
JSON, invalid runner selectors and budget overflows fail the consumer with a
persisted diagnostic; producer completion remains committed.

The original template remains in the immutable workflow snapshot. Schema 49 stores
the evaluated matrix and generated job definitions separately in the same database
transaction. A logical barrier waits for every instance before releasing downstream
jobs. Generated instances share the static matrix limits, provider authorization,
parallel cap, effective-result aggregation and output completion ordering. The run
page refreshes when expansion adds new jobs.

Restart and duplicate completion cannot expand a template twice. Failed-only reruns
reuse unaffected children and their saved outputs, rebuild affected children from
the original template and pinned inputs, and preserve the original event-resolved
environment. Expansion adds to the existing snapshot byte budget; virtual barriers
do not consume executable-job or step budgets.

Limits are 32 YAML nesting levels, 16 logical jobs, 16 axes, 256 combinations per
matrix, 256 expanded jobs per workflow, 4096 expanded steps and a 1-MiB normalized
snapshot.
Template/format results are charged in UTF-8 bytes before appending, and matrix
instances consume remaining job/step/plan budgets while they are constructed. The queue
page distinguishes dependency, concurrency-group and matrix-capacity waits.

## Upgrade and acceptance boundary

The baseline schema includes concurrency admissions and matrix scheduling
columns. Jobs default to no group, 256 parallel instances and fail-fast
disabled. Definition versions 1 and 2 remain readable and reruns preserve their
saved version. Historical scheduling snapshots use definition version 3 and
assignment version 6. Job-dataflow snapshots use definition version 4 and
assignment version 7; see [job dataflow](job-dataflow.md). Dispatch snapshots
use definition version 5 and assignment version 8 for [dispatch
inputs](dispatch-inputs.md). Definition-v6 snapshots use assignment version 9
for [repository variables](repository-variables.md). Old providers/runners
reject V6 instead of executing missing matrix contexts. Upgrade coordinator,
provider and runner together. Initialization preserves existing runs; see
[database compatibility](../db/README.md) for older databases.

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

Observed local Linux acceptance on November 5, 2026: the unchanged Editor Linux
instance passed all five steps through the actual V6 runner and HTTP protocol.
Upstream checkout v6 resolved to `d23441a48e516b6c34aea4fa41551a30e30af803`;
MoonBit `0.10.18+1fd8467c3-nightly` was installed by the original script. All-target
check and format passed; tests passed for wasm (1102), JS (1920) and native
(1246), with no wasm-gc tests discovered. The final success report and checkout
post cleanup were verified.

The first run on the local 12-CPU/8-GiB emulated x64 Docker environment terminated
several parallel link workers with `Killed`. Running the same commands with
`--cpuset-cpus=0-1` passed; no upstream script or compiler optimization mode was
changed. One intervening retry failed on a transient package-download TLS error.
Use a runner whose CPU/parallelism and memory are provisioned together. This is
Linux matrix-instance acceptance, not a claim of macOS/browser acceptance.

Current snapshots use definition v7 / assignment v10 for [workflow
OIDC](workflow-oidc.md). Historical definition versions 1–6 and their assignment
contracts remain readable.

Definition-v7 jobs without `id-token: write` retain assignment v9 compatibility;
only OIDC-enabled jobs require assignment v10.
