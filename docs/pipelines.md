# Pipelines: Step 1

The first delivery provides workflow validation and immutable run snapshots.
It does **not** execute repository code, start containers, add HTTP endpoints,
or expose a Pipelines page. Queued rows cannot be claimed by existing workers.

## Delivery Sequence

| Step | Scope | Status |
| --- | --- | --- |
| 1 | Workflow subset, authorization, immutable source/config snapshots, migration | Implemented; business APIs and tests only |
| 2 | Provider authentication, claims, attempts, leases, logs and result protocol | Planned |
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
  GitHub-hosted images. Actual label matching arrives with scheduling.
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
at most one active attempt can exist per job. State transitions and claiming
are deliberately deferred to step 2.

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
