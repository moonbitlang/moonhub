# Adaptive Linux execution routing

A logical execution environment maps a concrete Ubuntu label and architecture to
one provider per execution profile. Workflow YAML keeps its original `runs-on`.
Provider repository grants, labels, pause/revocation and privileged-worker isolation
gates remain mandatory. Jobs outside configured environments retain the existing
label-based routing.

`restricted` means the existing read-only non-root task container on a reusable
host. `linux-ci` means sudo and a job-local Docker daemon on a dedicated single-use
EC2. A capability request never changes a running container's privileges. Future
container-root profiles can provide package installation on reusable hosts without
Docker or host-kernel rights; they are not enabled by this change.

Execution profiles are independent of capacity purchase. Existing ASG
`purchase_policy` and `spot_wait_seconds` continue to select Spot with bounded
On-Demand fallback within each provider. Spot interruption recovery, checkpointing
and statistical cost optimization are separate additions; a capacity shortage or
ordinary failure is not classified as missing execution capability.

## Configure an environment once

Upgrade the coordinator, controllers, native workers and images together. Schema
043 adds environment mappings, repository retry policies, job routing snapshots,
positive capability observations and attempt diagnostics. Routed assignments use
version 13; older runners reject this version rather than silently running a job
without the capability-reporting contract. Historical assignments keep their old
versions and omit the new completion field when unused.

The site administrator first prepares providers with matching labels and images.
The Linux CI provider must follow the dedicated AMI, IAM and external network
requirements in [Single-use Linux CI](linux-ci-runner.md). Keep its fixed
`--linux-ci` controller option and outside metadata-disable acknowledgement.

Save `environment.json`:

```json
{
  "label": "ubuntu-24.04",
  "architecture": "x64",
  "environment_version": "v1",
  "routing": "adaptive",
  "restricted_provider": "linux-reusable",
  "linux_ci_provider": "linux-ci"
}
```

Then use an existing site-administrator access token:

```sh
moonhub auth status --json
moonhub environment list --json
moonhub environment set ubuntu-24.04-x64 --version 0 --body-file environment.json
```

`restricted` and `linux-ci` are also accepted as fixed routing policies. A fixed
policy requires its corresponding provider; adaptive routing requires both. The
provider names are configuration, not workflow selectors. Each environment owns
one provider for each profile, so demand is deterministic. Both queued-job counts
and atomic claims apply the same route constraint; two pools never scale for the
same routed job. Additional original job labels must still match the chosen
provider. An unavailable or unauthorized target does not grant an exception.

`environment_version` describes the administrator's image/toolchain contract.
Bump it when changing that contract to invalidate observations. Provider
replacement and procurement changes can retain the contract version. Pending jobs
for an obsolete version fail rather than silently switch their captured contract;
running attempts retain their assignments. Existing runs created before a mapping
was configured retain their original routing.

## Learn and retry

By default, a new job first uses the restricted profile. Platform-provided command
probes report explicit requests for `docker`, `container-root` or `host-kernel`.
For example `docker build` requests Docker, `sudo apt-get` requests container root,
and `sudo sysctl` requests host-kernel access. All three currently select
`linux-ci`, but the observation preserves the actual requested capability for
future profile selection. They never enable a host Docker socket or privileged
mode on a reusable worker.

A Docker command check (`--version`/`--help`) or configured remote Docker endpoint
does not request a new profile. A build error, arbitrary exit code or log message
cannot request a retry. Detection covers ordinary PATH-based shell and downloaded
JavaScript/composite Action commands; custom clients, absolute paths or commands
that replace PATH can bypass probes and fail normally. Successful restricted runs
continue probing future runs because repository scripts and runtime branches may
change without changing YAML. Observations are scheduling hints supplied by task
code; repository grants and retry limits are checked independently by the server.

Positive observations are keyed by repository, exact workflow source/path, expanded
job/matrix, environment contract and classifier version. Trust scope comes from
the captured run ref; merge-check scopes cannot update branch observations. The
key excludes the repository commit, so unrelated code commits retain learning.
Changing YAML or the environment contract starts a new key. The repository keeps
at most 2048 observation rows, evicting the oldest observations first. A miss
simply repeats the restricted probe.

A capability observation is saved even when automatic retry is disabled. Future
matching jobs go directly to Linux CI. A repository owner/admin may explicitly
allow one automatic capability retry for newly created runs:

```sh
moonhub ci policy --repo OWNER/REPO --json
moonhub ci set-policy --repo OWNER/REPO --version 0 --mode capability-retry
```

Use the current revision when updating, and `--mode no-retry` to disable. Policy
changes do not alter already-created jobs. Automatic retry executes the entire
job again and may repeat external side effects. Enabling it is appropriate only
when that repository's jobs tolerate repetition; the platform does not infer
idempotency from scripts or permission names.

The initial attempt remains visible as a failed attempt with a structured missing
capability reason. The logical job stays pending, downstream jobs and matrix
fail-fast wait, and no job outputs from the discarded attempt are published. Artifacts and cache entries
owned by that attempt are tombstoned before retry, freeing artifact names for
the replacement while normal blob cleanup reclaims their bytes. The
old attempt is fenced by its completed state. Its worker must remove the old task
container and workspace and explicitly acknowledge cleanup before the replacement
can be claimed. Cleanup failure or timeout ends the logical job. A new assignment
gets fresh credentials, workspace and attempt-scoped services. Previously issued
external credentials or completed external side effects cannot be revoked by
switching profiles.

Only one capability retry is permitted, only to a compatible authorized provider.
Cancellation takes precedence and the original job deadline covers both attempts
and their intervening queue/cleanup wait. An ordinary failure in the second
attempt is final. Purchase policy remains a separate field in attempt diagnostics;
it records configured purchasing policy, not a claim that an instance was
actually allocated as Spot.

```sh
moonhub ci execution RUN_NUMBER --repo OWNER/REPO --json
```

The response includes queued job routing decisions as well as attempt ordinals, providers, profiles, routing reasons,
purchase policies and explicit capability failures.

## APIs and validation

- `GET /-/api/v1/admin/execution-environments`: site admin with read scope.
- `POST /-/api/v1/admin/execution-environments/:name`: site admin with write scope;
  body `{ "revision": "0", "config": { ... } }`.
- `GET /-/api/v1/repos/:owner/:repo/execution-policy`: repository read.
- `POST /-/api/v1/repos/:owner/:repo/execution-policy`: owner/admin and execute
  scope; body `{ "revision": "0", "capability_retry": true }`.
- `GET /-/api/v1/repos/:owner/:repo/runs/:number/execution`: repository read.
- Worker-only `POST /-/runner-api/v1/workers/execution-cleanup`: completed
  attempt ownership and retry-cleanup fencing.

Run the pinned MoonBit check/fmt/info sequence, package boundaries, native
routing/protocol/runner regressions and HTTP authorization tests. Container smoke
must verify command probes and actual cleanup with a matching runner image;
unsafe-local execution is not cloud acceptance. Production rollout must separately
verify cold bootstrap, dedicated privilege boundaries and original workflows.
