# Pipelines: Steps 1 through 7

The first delivery provides workflow validation and immutable run snapshots.
The second adds a persistent runner protocol and authenticated machine API.
Step 3 adds a single-job Runner and a dedicated container image. Step 4 adds
the Docker provider and a dedicated DinD service. Step 5 adds DAG scheduling
and explicit reruns. Steps 6 and 7 add the browser controls, fault/recovery
coverage, orphan cleanup, and deployment topology acceptance. The server does
not execute repository code. Only explicitly provisioned providers can claim work.

## Delivery Sequence

| Step | Scope | Status |
| --- | --- | --- |
| 1 | Workflow subset, authorization, immutable source/config snapshots, migration | Implemented; business APIs and tests only |
| 2 | Provider authentication, claims, attempts, leases, logs and result protocol | Implemented; simulated-provider and HTTP acceptance tests |
| 3 | Single-job Runner and execution semantics | Implemented; native and HTTP execution tests plus container smoke |
| 4 | Docker provider, dedicated DinD, ephemeral jobs and isolation | Implemented; provider smoke and Compose overlay |
| 5 | Multi-job scheduling, concurrency and explicit reruns | Implemented; DAG scheduler and snapshot reruns |
| 6 | Repository pages and management controls | Implemented; run/provider pages and CSRF controls |
| 7 | Fault injection, recovery, cleanup and deployment acceptance | Implemented; recovery tests, orphan cleanup and topology smoke |

Each step is a separate implementation commit with its own acceptance tests.
Provider and DinD are separate services. Job containers must never receive
privileged mode, the Docker control socket/certificates, provider credentials,
or the application's data volume. Isolation checks accompany step 4, not step 7.

## Current Workflow Contract

Merge Requests can require these existing workflows through branch protection.
See [MR Pipeline checks](merge-checks.md) for setup, target-owned configuration,
merged-tree snapshots, execution approval, and the merge gate. This does not add
GitHub `pull_request` syntax or broaden the supported workflow language.

Workflow files are regular UTF-8 Git blobs directly under `.github/workflows/`,
with `.yml` or `.yaml` extensions and a nonempty ASCII filename starting with a
letter, digit or underscore. A run is requested from an existing local branch;
tags, arbitrary revision expressions and hidden refs are not accepted. Creating
a run resolves the branch once, then reads the workflow from that exact commit.

Supported configuration:

- `name`; `on: workflow_dispatch`, `on: push`, lists of these triggers, or a
  mapping containing either/both. Dispatch inputs are not yet supported.
  Push triggers handle branch creation/updates only. `push.branches` accepts
  1-64 exact branch names; omitted means all branches. Globs, negation, tag,
  path and PR filters are rejected, not silently approximated.
- Static `jobs`, `name`, `needs`, `runs-on`, `env`, `defaults.run`,
  `timeout-minutes`, and `steps`.
- Job labels must include `self-hosted`; the execution target is Linux. Labels
  are normalized to lowercase. There is no emulation of `ubuntu-latest` or other
  GitHub-hosted images. Providers must possess every requested label.
- Steps accept `id`, `name`, `run`, `shell`, `working-directory`, `env`, and
  `timeout-minutes`. Only literal `bash` and `sh` shell selections are accepted.
- Environment precedence is workflow < job < step. Values must be scalar;
  strings, integers, booleans, and real-number spellings are retained as strings.
  Names must be POSIX-like identifiers. `MOONHUB_`, `GITHUB_`, and `RUNNER_`
  prefixes are reserved for the executor.
  Shell/loader injection variables (`BASH_ENV`, `ENV`, `SHELLOPTS`, `BASHOPTS`,
  `LD_*`, `DYLD_*`) are also rejected by both parser and Runner.
- Defaults apply workflow < job < step. An omitted shell stays unspecified,
  because GitHub's implicit shell differs from explicitly selecting `bash`.
- Job timeouts default to 360 minutes; explicit job/step timeouts are integers
  from 1 through 360. The step timeout remains separate from the job deadline;
  the Runner does not restart the job deadline for each step.
- Working directories must be relative, without parent traversal, backslashes,
  control characters, empty path components, or drive prefixes. The executor
  must additionally enforce symlink containment at runtime.

All unknown fields are rejected before mapping. This includes `permissions`,
`concurrency`, `if`, `continue-on-error`, `strategy`, `container`, `services`,
`outputs`, `uses`, and `with`. `${{ ... }}` expressions are rejected rather than
executed literally. No field is silently stripped. `actions/checkout` is not
yet accepted: a later delivery must implement and test the action contract
before enabling it. The current Runner instead prepares a bounded archive of
the pinned commit before executing literal steps.

```yaml
name: Manual checks
on: workflow_dispatch
jobs:
  check:
    runs-on: [self-hosted, linux]
    timeout-minutes: 10
    steps:
      - id: hello
        shell: bash
        run: |
          printf '%s\n' 'Runner acceptance check'
  after:
    needs: check
    runs-on: self-hosted
    steps:
      - run: echo done
```

Limits: 64 KiB input, one YAML document, 32 collection levels, 8192 YAML nodes,
16 jobs, 64 steps per job, 256 steps overall, 100 environment entries per scope,
8 labels per job, and 1 MiB normalized plan JSON. Anchors, aliases, explicit tags,
merge keys, empty/duplicate keys, decoded NULs and invalid UTF-8 are rejected.
Dependencies must reference known jobs and form an acyclic graph. Generated step
IDs (`step_1`, etc.) cannot collide with explicit IDs.

YAML syntax comes from `moonbit-community/yaml@0.0.6`, retained in
`vendor/yaml` with its tests/license and a documented bounded-event callback
patch. Selected actrun model/mapping conventions are adapted with attribution in
`pipeline/workflow/THIRD_PARTY.md`. No actrun executor or dependency graph is used.

## Persistence and Authorization

`pipeline.create_run` requires a currently active repository owner/admin or site
administrator. Ordinary contributors cannot enqueue code execution. Read APIs
require current repository read access and scope all lookups by repository.
Permissions are rechecked after Git operations and before publishing a snapshot.

Migration 007 adds runs, jobs, dependency edges, and separate attempt history.
Run configuration is immutable and versioned. New runs contain no attempts;
jobs without dependencies are queued and dependent jobs are waiting. Lifecycle
state and conclusion are separate. Completed records require a conclusion, and
at most one active attempt can exist per job. Step 2 adds transactional claiming
and attempt transitions; Step 5 advances dependent jobs transactionally and
supports explicit reruns from an immutable completed snapshot.

The repository's existing cross-process write lock coordinates run creation.
Source is pinned under a random `refs/moonhub/pipelines/<token>` ref **before**
the SQLite transaction commits. The existing SSH `transfer.hideRefs` policy
already hides this namespace. Expected failures remove the pin and roll back
all rows. A crash between Git and SQLite may leave an orphan pin; it cannot leave
a committed run relying solely on a movable branch. Reconciliation/retention
arrives in step 7. Successful pins are retained until an explicit future cleanup
policy is implemented; this stage does not delete source snapshots.

## Acceptance

```sh
moon test --strip -j 1 vendor/yaml
moon test --strip -j 1 pipeline/workflow
moon test --strip -j 1 pipeline
moon test --strip -j 1 gitops database
moon test --strip -j 1
node scripts/check-package-boundaries.cjs
```

Tests cover upstream YAML behavior, multiline script preservation, scalar
coercion, defaults/env precedence, fail-closed validation, structural limits,
dependency cycles, current authorization, concurrent run numbering, rollback,
attempt constraints, migration from schema 6, database reopen, and source
retention after a force push plus immediate Git garbage collection. Those tests
do not execute workflow scripts or connect to Docker. Step 3 execution tests
run only application-owned fixtures.

## Runner Protocol (Step 2)

The machine API is mounted at `/-/runner-api/v1` separately from browser session
and login middleware. Its feature module requires an app-scoped `Coordinator`
injected by `web/dependencies.mbt`. Browser cookies cannot authenticate runners.
Use HTTPS outside a trusted local development connection; do not log Authorization
headers or claim request bodies in a reverse proxy.

Provider creation, pause/revocation, and repository grant changes are currently
business APIs requiring a live site-administrator identity. There is no default
credential, public registration endpoint, or registration UI. Step 4 adds the
`pipeline-provider-create` deployment command and Compose provider service. Each
provider starts with an explicit repository allowlist and normalized labels
including `self-hosted` and `linux`. No grant means no work. Each provider still
has one live attempt at a time; different providers can claim different ready
jobs. DAG scheduling and explicit reruns are described below.

### Credentials and Replay

Provider and attempt credentials are distinct 32-byte random values encoded as
64 lowercase hexadecimal characters. The provider must securely generate and
persist a fresh attempt credential and 16-byte random `request_id` **before**
requesting work. It must never give its long-lived provider credential to a job.
The service stores credential hashes, not plaintext credentials. Credential
values cannot be reused across provider and attempt roles or across attempts.

For successful allocations, retry the identical claim with the same request ID
and attempt credential after a lost response. The service returns the original
assignment without extending the lease. A retry with different credentials, or
after that attempt ends/expires, returns 409 rather than allocating another job.
Empty polls return `assignment: null` and are not persisted as reservations;
poll again with backoff. An assignment includes its current `state`: replaying
one already `running` is reconciliation, never permission to start a second
process. The Docker provider names its container by attempt ID and does not
retry a script after the container result is uncertain.

### Endpoints

Every request is POST with `Content-Type: application/json`, a Bearer credential,
and `version: 1`. Unknown fields and versions are rejected. Request bodies are
streamed with a 64 KiB cap and a 10-second read deadline, including chunked bodies.
Responses are JSON with `Cache-Control: no-store`; API errors do not redirect to
login and never include exception diagnostics or submitted secrets.

| Path (under the API prefix) | Credential | Additional request fields |
| --- | --- | --- |
| `/claims` | Provider | `request_id`, `attempt_token` |
| `/attempts/:id/start` | Attempt | `execution_id` (required by real Runners; optional for legacy clients) |
| `/attempts/:id/heartbeat` | Attempt | none |
| `/attempts/:id/steps` | Attempt | `step_id`, `state`, `exit_code` |
| `/attempts/:id/logs` | Attempt | `sequence`, `step_id`, `stream`, `text` |
| `/attempts/:id/complete` | Attempt | `conclusion`, `last_log_sequence` |

Claim responses contain `assignment` (object or null). Other responses contain
the attempt state, bound execution ID, acknowledged log sequence, lease deadline,
fixed job deadline, server time, cancellation flag, and conclusion when completed. Shared wire types
live in `pipeline/protocol`; no workflow AST, HTTP, or database types enter that
package. The wire plan uses an empty shell string for the implicit default and
step timeout `0` for no separate step limit. Numeric IDs, millisecond timestamps,
log sequences and cursors are explicit MoonBit `String` fields and decimal JSON
strings, preserving their full precision in JavaScript and other JSON consumers.
At computation/storage boundaries, parse canonical nonnegative decimal strings
within the signed 64-bit range; reject signs, whitespace, leading zeros, and
overflow. IDs must be positive. Database values and lease arithmetic remain
`Int64`; wire types do not rely on its derived JSON representation. Version,
timeout-minute and exit-code fields remain JSON numbers. The version 1 JSON
format is unchanged. Lease `deadline_ms: "0"` means
not yet started, and `conclusion: ""` means not completed. There are no
language-specific Option/enum encodings in the wire schema.

For example, a log upload contains `"sequence": "1"`, and completion contains
`"last_log_sequence": "1"`; numeric JSON values in these fields are rejected.
Errors use 400 (invalid input/version), 401 (bad credentials), 409 (expired,
out-of-order, or conflicting replay), and 413 (body/log limit). Unexpected errors
return a generic 500 response.

### State, Cancellation and Recovery

Claims are serialized with SQLite `BEGIN IMMEDIATE`, recheck current actor and
repository permissions, match labels, and atomically allocate a leased attempt.
Start is idempotent and records the fixed job deadline once. Leases last at most
60 seconds; running heartbeats renew up to the job deadline. Leased-but-not-started
heartbeats do not reserve work indefinitely. Responses include server time so
the Runner can derive a conservative monotonic local expiry after
subtracting request round-trip time and a safety margin. It must stop its entire
execution environment when it cannot renew safely, not wait for a reconnect.

`Coordinator.cancel_run` requires current repository-manager authorization.
Queued jobs are immediately cancelled; live attempts receive a durable request
and at most 15 seconds to acknowledge stopping. Repeated cancellation cannot
extend that window. Pause only prevents new claims; provider revocation or grant
removal also cancels its active work. Attempt heartbeats recheck the original
requester's current authorization. An authenticated completion following a
cancellation is recorded as cancelled, with the reported outcome separately
retained. A completed attempt only accepts an identical completion replay.

The Web lifecycle owns a lease worker checking expiry every two seconds in
bounded batches. Requests also reconcile expiry. Lease loss or an unacknowledged
cancel becomes `lost`, not success or an automatic retry. A reached job deadline
becomes `timed_out` if the lease remained valid until that deadline. Old attempt
credentials cannot update a later attempt. Step 3 adds stopping inside the
execution container; Step 4 adds provider-side container supervision. External
side effects are never guaranteed exactly-once.

### Logs

Log sequences are consecutive per attempt, starting at 1 across all steps and
streams. Duplicate sequence/content pairs are acknowledged without duplication;
changed or out-of-order uploads fail. Completion must cite the last acknowledged
sequence. Chunk payloads are at most 8 KiB UTF-8, with at most 1 MiB and 4096
chunks per attempt. Streams are `stdout` or `stderr`; a step ID must match the
definition, or be empty for job-level setup logs.

The service masks the literal attempt credential, including matches spanning
chunks of the same step/stream. It temporarily withholds only a matching suffix
and flushes it on termination if it never becomes a full credential. This is
not protection against deliberate credential transformation/exfiltration. The
Runner keeps control credentials out of user scripts, and provider
credentials never belong in logs. General workflow secrets are not yet supported.

`Coordinator.read_logs` rechecks repository access and attempt/run scope, returns
at most 100 records with stable cursor IDs, and never renders log text as HTML.
`Coordinator.read_log_page` additionally returns `next_cursor`, `has_more` and
`complete`. Attempt state and log records are read in one database snapshot:
`complete` is true only after the attempt has terminated and this page reaches
the end, including any suffix flushed during termination. Cursor IDs, unlike
runner upload sequences, also cover these flushed records.

Pipeline detail pages are initially server-rendered, then updated by JavaScript
without reloading the document. Browser-session endpoints are:

- `GET /:owner/:repo/pipelines/:number/updates`: run, job, step and queue state.
- `GET /:owner/:repo/pipelines/:number/attempts/:attempt/logs?after=0`:
  a bounded incremental log page. All IDs and cursors are decimal strings.

These endpoints require repository read access and use `Cache-Control: no-store`;
runner/provider tokens do not authorize browser requests. Polling is serialized
at two-second intervals, with immediate continuation for a log backlog. Each
completed log stream stops independently. Once the run is terminal and every
stream has reached `complete`, all polling stops. Opening a completed run still
drains any log pages beyond the initial server-rendered page before stopping.
Transient failures retry with capped backoff, revoked access stops requests,
hidden tabs pause, and navigation cancels outstanding requests.

Logs use the document's normal vertical scrolling. There is no whole-job log
disclosure. Running jobs show continuous output. For a completed job with more
than 200 loaded lines, the enhanced view initially shows the first 20 and last
80 lines, with a button to expand the middle in batches of up to 1,000 lines.
Search automatically reveals matches in hidden middle output. Expansion is
preserved while polling drains the final backlog. Job and step selection share
the same output area.
Search and error-keyword navigation scroll the page to real matching output;
the explicit Follow control keeps the end visible. Polling preserves the page's
reading position when Follow is off. No log
contents or UI state are stored in browser storage. Without JavaScript the page
remains a static snapshot that can be reloaded manually. Persistence uses SQLite;
retention policy and external storage are not implemented. The enhanced view
bounds a running/search window to 5,000 lines; search covers loaded output, and Copy and
Download include all loaded output for the selected step(s).

After building the native executable and frontend assets,
`node scripts/pipeline-logs-browser-smoke.cjs` verifies incremental rendering,
completion/backlog stopping, final redaction-tail delivery, retry and pause
behavior on an isolated local server. `MOONHUB_KEEP_PREVIEW=1` retains that server
and writes connection details to `_build/pipeline-logs-browser/preview.json`.

### Additional Acceptance

```sh
moon test --strip -j 1 --deny-warn pipeline database web/views/pipelines
```

Tests exercise production bearer-vs-cookie authentication, a simulated HTTP
provider's complete lifecycle, lost-response claim replay, separate database
connections competing for a job, database close/reopen, reordered/duplicate
logs, credential redaction, log quotas, cancellation/result races, revoked
permissions, expired/old credentials, fixed deadlines, and migration 7 -> 8
including backfilled labels. No Docker daemon or external service is needed.

## Automatic Push Workflows

Automatic execution is opt-in per repository. A repository owner or administrator
can enable **Run push workflows** on its Pipelines page. Existing repositories
remain disabled after migration 012. Only pushes by repository owners/admins or
site administrators are eligible, preserving the existing execution trust policy;
ordinary contributors can still push, but their pushes do not automatically run
code. The requester must remain authorized when the event is processed and when
a provider claims it. Provider scopes and label matching still apply. No fork or
external-contributor execution is enabled.

```yaml
on:
  workflow_dispatch:
  push:
    branches: [master]
```

SSH branch updates and successful in-app merges create durable repository events.
Tag pushes, branch deletion and unchanged refs do not create jobs. Workflow files
and sources are read from the event's exact new commit, never the branch's later
tip. At most 64 workflow files are inspected for an event; each matching workflow
gets an independent immutable run. Unsupported workflow files are reported in
**Recent push events** without preventing other valid workflows from running.
This includes GitHub-only workflows in the same `.github/workflows` directory.
Disabling automatic execution prevents pending events from creating new runs;
it does not cancel already-created runs. Enabling it does not replay older pushes.

The deployment-owned `reference-transaction` hook records the intent during
Git's `prepared` phase. `committed` and `aborted` callbacks confirm its outcome;
the optional newer `preparing` phase is ignored. The SSH parent holds the
repository write lock across receive-pack and event recovery. Before another
managed write, recovery confirms unacknowledged intents against the current ref
and pins successful commits under `refs/moonhub/push-events/`. If neither old nor
new value matches, writes fail closed for inspection instead of guessing. This
relies on all writes going through MoonHub's shared per-repository lock; direct
external ref edits are not supported. Merge events are recorded alongside merge
completion and recover from the existing atomic merge receipt.

The background worker handles persisted events after restart. A unique
event/workflow key makes replay idempotent; each run also owns a distinct source
pin. Temporary processing errors retry after 30 seconds without starving other
repositories. Events and retained pins are currently not pruned automatically.
Public trigger status does not expose internal exception details.

Upgrade Web and SSH together: both trusted hooks (`pre-receive` and
`reference-transaction`) must be installed and executable; missing or
non-executable hooks fail closed. Docker installs both automatically. The hooks
never come from the pushed repository. `.github/workflows/moonhub.yml` now allows
pushes to `master` as well as manual dispatch; enabling the repository setting is
still an explicit operator action.

`node scripts/pipeline-push-smoke.cjs` runs the native SSH command, actual
receive-pack and deployment hooks with an isolated database. Its local transport
shim replaces SSH networking only. It covers opt-in, two pushes while Web is
stopped, multiple workflows, fixed SHAs, restart/no-op deduplication and filters.
`MOONHUB_KEEP_PREVIEW=1` retains the preview under
`_build/pipeline-push-smoke/preview.json`. No production deployment is touched.

## Single-job Runner (Step 3)

`moonhub runner` consumes one bare `Assignment` JSON file and one 64-character
attempt credential from stdin. It does not claim jobs, access the database,
load `.env`, or accept a provider credential. An assignment must still be leased,
the workspace must be empty, and the server must be an origin without a path,
query, fragment, or embedded credentials. HTTPS uses the system trust store;
plain HTTP requires the explicit `--allow-http` development flag. Redirects are
not followed and response bodies/retries are bounded.

The Runner generates a fresh `execution_id` before its first `/start` request.
Migration 009 binds that ID once and adds persisted per-step states. Start
retries from the same instance are idempotent; a different Runner instance is
rejected, even if it receives the same assignment and attempt credential.
Older simulated clients may still use the legacy start shape, but real Runners
require the echoed execution ID and fail closed against an older server.

The additional `/attempts/:id/steps` endpoint accepts `version`, `step_id`,
`state`, and `exit_code`. It enforces pending -> running -> terminal transitions,
ordered execution, and idempotent repeats. Fenced executions cannot report job
success until every step succeeded. Terminalization records interrupted running
steps and skips pending ones. `Coordinator.read_steps` is repository-scoped;
the step UI remains part of step 6.

### Execution and Isolation

- Each literal `run` starts a new shell, with workflow/job/step environment
  already resolved in the plan. The workspace is shared within the job, but shell
  variables, `cd`, and exports do not leak into later shells.
- Implicit Bash uses `-e`; explicit Bash uses `-e -o pipefail`; `sh` uses `-e`.
  Custom shell templates and file commands such as `GITHUB_ENV` are not supported.
- The child environment is constructed explicitly, never inherited from the
  controller. It includes the assigned repository/SHA/workspace, CI markers and
  private HOME/TMPDIR directories. The image's MoonBit tools are read-only under
  `/opt/moon`, with writable per-job cache space under the job HOME.
- Script paths are generated by the controller; working directories are checked
  against the canonical workspace, including symlinks. This is a configuration
  check, not an OS filesystem sandbox: container mounts define the real boundary.
- Stdout/stderr are streamed with bounded reads and incremental UTF-8 handling.
  One uploader serializes global log sequence numbers; retries reuse the exact
  payload. Invalid UTF-8 is replaced. Output caps stop the job rather than growing
  memory indefinitely. After a shell exits, log drain is bounded to 250 ms so a
  background pipe holder cannot stall subsequent steps; redirect long-lived
  background process output to workspace files when needed.
- A monotonic watchdog enforces the lease and fixed job deadline independently
  of heartbeat I/O. Linux uses a suspend-aware clock. Heartbeats default to five
  seconds. Step timeouts cannot extend the job deadline. Cancel, timeout, lease
  loss and interruption stop execution before reporting; scripts are never retried.
- A small POSIX launcher creates a new session/process group before `exec` of the
  shell. Cancellation kills that group, not just its leader. Successful background
  processes may survive between steps but are cleaned up at job end.
- Production mode requires **non-root PID 1 in an isolated Linux PID namespace**.
  It disables dumps/ptrace access to controller secrets and enables no-new-privileges.
  At job end it kills and reaps all other processes in that namespace, including
  descendants that detached into another session. Do not wrap this image in
  `--init`, use host PID mode, give it a Docker socket, or mount application data.
- `--unsafe-local` deliberately bypasses the container requirement for trusted
  development fixtures. It cannot contain malicious scripts, detached processes,
  or access to the host filesystem and must not be used for repository workloads.

The Runner outputs a JSON report. Exit 0 means server-confirmed success; exit 1
means a confirmed non-success result; exit 2 means configuration failure or an
unconfirmed result. Final metadata/completion retries have a three-second budget
after process cleanup. A local result is not authoritative unless `reported` is
true. Container/host crashes still require provider supervision and server lease
expiry; external side effects remain outside exactly-once guarantees.

### Image and Acceptance

The `runner` Dockerfile target shares the locally cached dependency base with
Web/SSH and provider. It contains Bash, Git, a C toolchain, Node/npm and the real
MoonBit distribution.
It runs as UID/GID 10001 and enters the Runner directly as PID 1. The provider
must still apply mount, network, CPU, memory and PID limits when creating it.
The workspace mount must allow execution of build outputs. The job is non-root,
with all capabilities dropped and `no-new-privileges`; `/tmp` remains a bounded
`noexec,nosuid,nodev` tmpfs. The provider uses a disposable disk volume for
`/workspace` (the standalone Runner smoke still uses a small tmpfs fixture).

```sh
./deploy/deploy.sh build-base
docker build --target runner -t moonhub:runner-step3 .
node scripts/runner-container-smoke.cjs
```

The smoke test uses an isolated mock control server and temporary manifest, not
the deployed application or real repositories. It runs a read-only container
with all capabilities dropped, no-new-privileges, bounded memory/CPU/PIDs, and
temporary writable workspace/tmp mounts. It verifies non-root execution,
controller credential isolation, absence of the Docker socket/application data,
real native `moon run`, cancellation, and removal of detached descendants before
completion. It cleans up only its own containers and temporary files.

Native execution and real HTTP integration tests need the system C compiler but
no Docker daemon:

```sh
moon test --strip -j 1 --deny-warn runner pipeline web/views/pipelines
```

Each Runner now downloads a tar snapshot of its pinned commit before literal
steps execute. Only a live, running, authorized attempt can read the source;
completed, expired, cancelled and revoked credentials are rejected. The request
is bounded to 30 seconds, 64 MiB and 10,000 regular files. The initial archive
checkout rejects symlinks, submodules and runner-reserved paths (`.git`, `.home`,
`.tmp`), preserves executable files and binary data, and does not create `.git`
or fetch LFS objects. Git archive attributes apply. This is not yet an
implementation of `actions/checkout` or arbitrary `uses` actions.
The provider creates one isolated container per ready DAG Job; workspaces are
not shared across jobs. Trusted local tests use the same source-fetch path.

## DAG Scheduling and Reruns (Step 5)

Jobs without `needs` enter `queued`; dependent jobs enter `waiting`. After an
attempt completes successfully, its direct dependents become queued when all
their dependencies succeeded. If any dependency concludes with failure,
timeout, cancellation, loss, or skip, the dependent job is completed as
`skipped`; this propagates through deeper branches in the same transaction.
Claims can continue from a Run whose status is already `running`, so a provider
can execute each ready Job in order. A provider still has one active attempt;
parallelism comes from multiple provisioned providers and matching labels.

`rerun_run` accepts a completed Run under the normal repository-manager
authorization. It creates a new Run number and Git pin for the original commit,
copies the immutable workflow source/definition, and resets all Job states.
It never reparses the current branch, so a force-push cannot change what the
rerun executes. Active Runs cannot be implicitly rerun; cancellation and
recovery remain explicit operations.

The Run detail page offers snapshot rerun. Per-repository concurrency policy is
not yet implemented.

## Docker Provider (Step 4)

The provider is a separate `moonhub:provider` service. It reads its long-lived
provider credential from `/run/secrets/provider_token`, claims at most one live
attempt, writes the assignment to a private shared control volume, and invokes
the configured Runner image through the DinD daemon. The attempt credential is
written only to the Runner process stdin. It is never a Docker argument,
environment variable, volume, or job file.

The Compose overlay is intentionally separate from the default Web/SSH stack:

```sh
mkdir -p deploy/secrets
(umask 077; openssl rand -hex 32 > deploy/secrets/provider_token)
docker compose -f compose.yaml -f deploy/compose.pipeline.yaml \
  config --quiet
```

Register the provider once, using the same token file. This command uses the
Web container's database but does not put the token in argv:

```sh
docker compose exec -T web sh -eu -c '
  umask 077
  cat > /tmp/moonhub-provider-token
  moonhub pipeline-provider-create \
    --name dind --token-file /tmp/moonhub-provider-token \
    --labels self-hosted,linux --repositories alice/demo
  rm -f /tmp/moonhub-provider-token
' < deploy/secrets/provider_token
```

Site administrators can also manage providers at
`/-/admin/pipelines/providers`: create a provider, edit its labels or repository
access, pause/resume it, or revoke it. **Edit access** offers two scopes:

- **Selected repositories**: only the listed repositories may use this provider.
  An empty list allows no jobs. This is the default, including migrated providers.
- **All repositories**: all current and future repositories may use this
  provider, without individual grants. Labels still have to match, and the
  workflow requester must still be authorized to run jobs in the repository.

Saving access atomically replaces the scope and selected repository list. Newly
eligible queued jobs can be claimed without rerunning them. Assigned jobs outside
the new scope are marked for cancellation; unassigned jobs remain queued. Tokens,
labels and paused state are preserved. Only site administrators may change scope.
Do not share a provider across repositories whose job code you do not trust with
its execution environment.

Provider state and connectivity are shown separately: active/paused/revoked is
administrative state, while recent contact means a claim or lease renewal within
the last minute. Run detail pages explain queue blockers, including authorization,
labels, paused/busy providers and missing recent contact, without exposing
provider identities or other repositories' grants.

**Edit labels** replaces the provider's label set atomically;
`self-hosted` and `linux` remain required (up to 8 labels, each 1-64 ASCII letters,
digits, underscores or hyphens; case is normalized). Token, repository grants,
name and paused state are unchanged. Revoked providers cannot be edited.

The next provider claim uses the updated labels, so newly matching queued jobs
do not need to be rerun or re-registered. Existing leased/running attempts that
no longer match are marked for cancellation in the same transaction. Runner
heartbeats observe this and stop execution; still-matching work is untouched.
Cancellation must finish (or its lease/cancellation grace expire) before that
provider claims its next job. Re-adding a removed label does not undo an issued
cancellation. If the Runner cannot confirm completion before the grace period,
the attempt is `lost`, not falsely reported as successfully cancelled.

Deployment `pipeline-provider-ensure` remains additive: labels configured in
`MOONHUB_PROVIDER_LABELS` will be added again on a later upgrade. Update that
operator setting too when permanently removing a provisioned label.
Both provider CLI commands accept `--scope selected|all`. Create defaults to
selected; ensure without `--scope` preserves existing scope (or uses selected
for a new provider). Selected repository grants are also additive in ensure;
use **Edit access** for replacement or removal. Explicit `--scope all` requires
an empty repository list and clears selected grants. Set
`MOONHUB_PROVIDER_SCOPE=all` and clear `MOONHUB_PROVIDER_REPOSITORIES` in
`deploy/deploy.env` to provision a shared provider through `deploy.sh upgrade`.
Omitting the scope environment variable preserves edits made in Administration.
The browser shows a newly generated provider token only in the creation
response; store it in the provider secret immediately. Existing deployments
may continue using the CLI flow above for non-interactive provisioning.

`node scripts/provider-labels-browser-smoke.cjs` verifies label and access editing against
an isolated local server (build the native executable and frontend assets first).
It covers selected/all scopes, validation round-trips, save/cancel, paused state and desktop/mobile
layouts. `MOONHUB_KEEP_PREVIEW=1` retains its local preview and writes connection
details to `_build/provider-labels-browser/preview.json` without touching an
existing deployment.

Start the provider and DinD services with a pinned Runner image available from
the configured registry. A digest is preferred over a mutable tag:

```sh
MOONHUB_RUNNER_IMAGE=registry.example/moonhub-runner@sha256:<digest> \
docker compose -f compose.yaml -f deploy/compose.pipeline.yaml \
  up -d --build --wait
```

Only `pipeline-docker` is privileged. Docker has no TCP listener; a dedicated
Unix socket volume is mounted only in DinD and the provider, never Web or jobs.
Jobs use their own bridge network namespace to reach the internal Runner API.
Job containers are
created with dropped capabilities, no-new-privileges, read-only rootfs,
resource limits, a bounded `/tmp` tmpfs, a private disposable `/workspace` disk
volume, and no application volumes. The
provider and DinD share the socket and assignment control volumes. DinD image
storage is persisted separately. The default pipeline subnet is `172.30.90.0/24`;
set `MOONHUB_PIPELINE_PREFIX` and `MOONHUB_PIPELINE_NETWORK` when another isolated
deployment already uses it. Provider initialization copies its file secret to a
private runtime directory and then drops to UID/GID 10001.

Retain the official DinD entrypoint and pass `dockerd` explicitly as the first
command argument. This runs its cgroup nesting initialization without adding
default TCP listeners. Do not bypass initialization or disable job resource
limits to work around nested cgroup failures. `node scripts/dind-smoke.cjs`
verifies enforced CPU, memory and PID limits on cgroup v2 before and after a
daemon restart, using a disposable Compose project and locally cached DinD image.

The provider smoke test uses a real provider binary and mock HTTP/Docker
adapters:

```sh
moon build --strip -j 1 --deny-warn
node scripts/provider-smoke.cjs
```

On startup the provider removes only containers named `moonhub-pipeline-*` in
its configured Docker daemon. This makes a provider restart recover stale DinD
containers without touching unrelated workloads. The attempt lease remains the
source of truth: stale containers are not retried as successful work, and an
expired attempt is reconciled as lost by the Web service.

Each assignment allocates a fresh `moonhub-workspace-<attempt>-<random>` volume
with the `io.moonhub.pipeline.workspace=1` label. Docker initializes its empty
mount from the Runner image's `/workspace` ownership so UID 10001 can write it.
Successful, failed and cancelled runs remove the container and then its volume;
cleanup failure stops the provider before more claims. Startup removes stale
job containers first, then only labeled workspace volumes. A provider must have
its own Docker daemon. No blanket volume prune is used, and workspaces are never
reused across attempts.

The volume uses the DinD data disk, not tmpfs. Standard Docker local volumes do
not provide a portable per-volume size quota. There is currently no hard disk
capacity limit per job; 20 GiB is the intended default when a quota-capable
backend is added, not an enforced setting today. Use dedicated DinD storage and
monitor free space; an untrusted job can otherwise exhaust that disk. Process
memory, CPU and PID limits remain in force (filesystem page cache can still
count toward memory usage).

The deployment smoke validates the Compose topology without starting services:

```sh
MOONHUB_PROVIDER_TOKEN_FILE=/dev/null \
node scripts/pipeline-deployment-smoke.cjs
```

It checks the privileged boundary, private Unix socket, bridge network and Web's
normal SSH network. `node scripts/pipeline-e2e.cjs` exercises a separate real
Compose project using prebuilt `moonhub:acceptance`, `moonhub-provider:acceptance`
and `moonhub-runner:acceptance` images (overridable with the usual image variables).
It initializes an account/repository, runs the upgrade script, force-pushes after
dispatch, verifies source bytes and a native MoonBit build, cancels another run,
and repeats upgrade/ensure while checking backups and persisted results. It
retains only its named acceptance project and writes connection settings and
test results under `_build/moonhub-acceptance-*` for inspection. No registry is
needed when local Runner images are loaded into DinD by the deploy script.

## MoonHub Self-Hosting Checks

`.github/workflows/moonhub.yml` runs a manual check of this repository using the
existing archive checkout. It requires `self-hosted`, `linux` and `moonhub-build`
provider labels. The `runner-selfhost` target remains compatible with existing
settings; the shared dependency base now includes Node/npm in both Runner
targets. Docker CLI binaries are also present in the shared base, but jobs have
no Docker socket or deployment credentials. MoonBit defaults to `0.10.14+7d59c7ec9` across
Web, provider and Runner builds. Preserve the built images for recovery: upstream
toolchain archives have limited retention.

For the provider assigned to MoonHub, use these settings in `deploy/deploy.env`
(replace the repository path with its registered namespace):

```sh
MOONHUB_ENABLE_PIPELINES=1
MOONHUB_RUNNER_BUILD_TARGET=runner-selfhost
MOONHUB_PROVIDER_LABELS=self-hosted,linux,moonhub-build
MOONHUB_PROVIDER_SCOPE=selected
MOONHUB_PROVIDER_REPOSITORIES=moonhub/moonhub
MOONHUB_RUNNER_MEMORY=4g
MOONHUB_RUNNER_CPUS=2
```

`scripts/self-check.cjs` initializes the registry in the fresh job HOME, then
prints each stage's start, result and elapsed time, with a progress line every
30 seconds while a command is running. Dependency installation has a five-minute
stage deadline; native tests and compilation each have ten minutes. The workflow's
30-minute job deadline still bounds the entire run. A stage timeout terminates
its process group and fails the check without starting later stages. It then
runs check/fmt/info in order, rejects modified or
added/deleted MoonBit inputs and interfaces without requiring `.git`, checks
package boundaries, builds frontend assets, then runs all native tests and builds
the executable. The source checkout is not a deployment working tree. Production
upgrades and Docker integration tests remain external to the job.

After building `moonhub:acceptance`, `moonhub-provider:acceptance` and
`moonhub-runner:selfhost` from a clean checkout, run:

```sh
MOONHUB_E2E_SELFHOST=1 node scripts/pipeline-e2e.cjs
```

This imports the committed MoonHub repository into a disposable instance, runs
the real self-check workflow, and retains its commit/run receipt alongside the
checkout, cancellation and upgrade acceptance results. Self-hosting mode defaults
to loopback ports 18083/12225 and subnet 172.30.93.0/24; the E2E port/subnet
overrides remain available. Run `node --test scripts/self-check-test.cjs` to check
the archive-formatting guard independently.
