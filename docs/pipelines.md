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

The separate `runner` Dockerfile target keeps the existing default Web/SSH image
unchanged. It contains Bash, Git, a C toolchain, and the real MoonBit distribution.
It runs as UID/GID 10001 and enters the Runner directly as PID 1. The provider
must still apply mount, network, CPU, memory and PID limits when creating it.
The workspace mount must allow execution of build outputs (`exec,nosuid,nodev`);
the separate `/tmp` mount may use `noexec,nosuid,nodev`.

```sh
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
`/-/admin/pipelines/providers`: create a provider, pause/resume it, or revoke
it. The browser shows a newly generated provider token only in the creation
response; store it in the provider secret immediately. Existing deployments
may continue using the CLI flow above for non-interactive provisioning.

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
resource limits, temporary filesystems, and no application volumes. The
provider and DinD share the socket and assignment control volumes. DinD image
storage is persisted separately. The default pipeline subnet is `172.30.90.0/24`;
set `MOONHUB_PIPELINE_PREFIX` and `MOONHUB_PIPELINE_NETWORK` when another isolated
deployment already uses it. Provider initialization copies its file secret to a
private runtime directory and then drops to UID/GID 10001.

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
