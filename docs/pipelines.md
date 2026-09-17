# Pipelines: Steps 1 and 2

The first delivery provides workflow validation and immutable run snapshots.
The second adds a persistent runner protocol and authenticated machine API.
Neither executes repository code, starts containers, or exposes a Pipelines
page. Only explicitly provisioned providers can claim single-job runs.

## Delivery Sequence

| Step | Scope | Status |
| --- | --- | --- |
| 1 | Workflow subset, authorization, immutable source/config snapshots, migration | Implemented; business APIs and tests only |
| 2 | Provider authentication, claims, attempts, leases, logs and result protocol | Implemented; simulated-provider and HTTP acceptance tests |
| 3 | Single-job Runner and execution semantics | Planned |
| 4 | Docker provider, dedicated DinD, ephemeral jobs and isolation | Planned |
| 5 | Multi-job scheduling, concurrency and explicit reruns | Planned |
| 6 | Repository pages and management controls | Planned |
| 7 | Fault injection, recovery, cleanup and deployment acceptance | Planned |

Each step is a separate implementation commit with its own acceptance tests.
Provider and DinD will be separate services. Job containers must never receive
privileged mode, the Docker control socket/certificates, provider credentials,
or the application's data volume. Isolation checks accompany step 4, not step 7.

## Current Workflow Contract

Workflow files are regular UTF-8 Git blobs directly under `.github/workflows/`,
with `.yml` or `.yaml` extensions and a nonempty ASCII filename starting with a
letter, digit or underscore. A run is requested from an existing local branch;
tags, arbitrary revision expressions and hidden refs are not accepted. Creating
a run resolves the branch once, then reads the workflow from that exact commit.

Supported configuration:

- `name`; `on: workflow_dispatch`, its one-element list form, or a mapping with
  `workflow_dispatch: null` / `{}`. Dispatch inputs are not yet supported.
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
- Defaults apply workflow < job < step. An omitted shell stays unspecified,
  because GitHub's implicit shell differs from explicitly selecting `bash`.
- Job timeouts default to 360 minutes; explicit job/step timeouts are integers
  from 1 through 360. The step timeout remains separate from the job deadline;
  the future executor must not restart the job deadline for each step.
- Working directories must be relative, without parent traversal, backslashes,
  control characters, empty path components, or drive prefixes. The executor
  must additionally enforce symlink containment at runtime.

All unknown fields are rejected before mapping. This includes `permissions`,
`concurrency`, `if`, `continue-on-error`, `strategy`, `container`, `services`,
`outputs`, `uses`, and `with`. `${{ ... }}` expressions are rejected rather than
executed literally. No field is silently stripped. `actions/checkout` is not
yet accepted: a later delivery must implement and test the restricted checkout
contract before enabling it. A pinned source commit is not an implicit checkout.

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
and attempt transitions; dependent multi-job scheduling remains deferred.

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
retention after a force push plus immediate Git garbage collection. No test
executes workflow scripts or connects to Docker.

## Runner Protocol (Step 2)

The machine API is mounted at `/-/runner-api/v1` separately from browser session
and login middleware. Its feature module requires an app-scoped `Coordinator`
injected by `web/dependencies.mbt`. Browser cookies cannot authenticate runners.
Use HTTPS outside a trusted local development connection; do not log Authorization
headers or claim request bodies in a reverse proxy.

Provider creation, pause/revocation, and repository grant changes are currently
business APIs requiring a live site-administrator identity. There is no default
credential, public registration endpoint, CLI provisioning, or registration UI.
Those deployment entry points follow with the real provider in step 4. Each
provider starts with an explicit repository allowlist and normalized labels
including `self-hosted` and `linux`. No grant means no work. This stage allows
one live attempt per provider and only one-job runs; it does not partially run
multi-job workflows. Global concurrency and DAG scheduling arrive in step 5.

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
process. The future provider must name/reconcile resources by attempt ID.

### Endpoints

Every request is POST with `Content-Type: application/json`, a Bearer credential,
and `version: 1`. Unknown fields and versions are rejected. Request bodies are
streamed with a 64 KiB cap and a 10-second read deadline, including chunked bodies.
Responses are JSON with `Cache-Control: no-store`; API errors do not redirect to
login and never include exception diagnostics or submitted secrets.

| Path (under the API prefix) | Credential | Additional request fields |
| --- | --- | --- |
| `/claims` | Provider | `request_id`, `attempt_token` |
| `/attempts/:id/start` | Attempt | none |
| `/attempts/:id/heartbeat` | Attempt | none |
| `/attempts/:id/logs` | Attempt | `sequence`, `step_id`, `stream`, `text` |
| `/attempts/:id/complete` | Attempt | `conclusion`, `last_log_sequence` |

Claim responses contain `assignment` (object or null). Other responses contain
the attempt state, acknowledged log sequence, lease deadline, fixed job deadline,
server time, cancellation flag, and conclusion when completed. Shared wire types
live in `pipeline/protocol`; no workflow AST, HTTP, or database types enter that
package. The wire plan uses an empty shell string for the implicit default and
step timeout `0` for no separate step limit. All Int64 values (numeric IDs,
millisecond timestamps, log sequence and cursor values) are decimal JSON strings
to preserve their full precision in JavaScript and other JSON consumers. Version
and timeout-minute fields remain JSON numbers. Lease `deadline_ms: "0"` means
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
the future runner can derive a conservative monotonic local expiry after
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
credentials cannot update a later attempt. This is durable bookkeeping, not a
claim that this stage can terminate a process: actual stopping arrives with the
runner/provider, and external side effects are never guaranteed exactly-once.

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
future executor must keep control credentials out of user scripts, and provider
credentials never belong in logs. General workflow secrets are not yet supported.

`Coordinator.read_logs` rechecks repository access and attempt/run scope, returns
at most 100 records with stable cursor IDs, and never renders log text as HTML.
Browser log routes arrive in step 6. Persistence uses SQLite in this stage;
retention policy and external storage are not implemented.

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
