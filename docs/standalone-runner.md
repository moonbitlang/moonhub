# Standalone MoonHub runner

`moonhub-runner` is a separate native executable. MoonHub owns repository grants,
job scheduling and durable configuration; the runner owns its backend and worker
resources. The server has no AWS dependency. Existing `moonhub pipeline-provider`
and `moonhub runner` commands remain supported. The baseline schema stores
provider credentials and task history.

## Build and register

```sh
moon build --strip -j 1
_build/native/debug/build/cmd/moonhub-runner/moonhub-runner.exe --help
```

Install the executable as `/usr/local/bin/moonhub-runner`. Build the Docker
`runner` target for task execution; its entry point invokes `moonhub-runner execute`
and includes the toolchain, step launcher and Node 20/24 Action runtime. Use matching
server/controller/task versions and rebuild the dependency base for assignment v5.
See [GitHub Action execution](github-actions.md) for supported metadata and source limits.

In **Pipeline providers**, create a provider with the intended labels and repository
grants. Save its one-time registration token in a 0600 file. The CLI name must
match this authorization record.

```sh
moonhub-runner run \
  --server https://moonhub.example --name local-ci --mode docker \
  --registration-token-file /etc/moonhub-runner/registration-token \
  --state-dir /var/lib/moonhub-runner/controller \
  --workspace-root /var/lib/moonhub-runner/workspace \
  --runner-image registry.example/moonhub:runner
```

The initial connection publishes the schema/defaults and exchanges the registration
token for a locally generated controller token. Retries are idempotent; the original
registration token cannot replace an enrolled identity. Preserve the private state
directory across restarts. It is bound to one server, provider name and mode. The
registration file can be removed after enrollment. Never pass secrets as arguments.
HTTPS is required; `--allow-http` is only for trusted development networks.

One controller holds a 60-second server lease. A restart may wait for that lease.
Use systemd `Restart=on-failure` and an appropriate `RestartSec`. Docker mode drains
previous workers before starting its single worker and reconciling stale containers.
Use one provider per dedicated Docker daemon: cleanup owns `moonhub-pipeline-`
containers and labeled MoonHub workspace volumes.

## Runtime configuration

Linux Docker providers can offer several distribution-specific task
images with shared capacity; see [provider environments](provider-environments.md).
Without named environments, the existing runner-image setting remains authoritative.

Open **Execution settings** beside the provider. The server renders its bounded
schema using generic text, integer and choice fields. No AWS credentials are stored.

- Docker and Linux CI: runner image, CPU and memory limits per job.
- ASG: instance type from the local allowlist, total worker limit, standby worker
  count, idle timeout, numeric launch-template version, purchase policy and Spot
  wait timeout. Standby workers are kept idle in addition to active and queued
  work; total workers remain capped by Maximum workers. The default standby count
  is zero, and pausing the provider scales all workers down.

Saves use compare-and-swap revisions. Desired, observed and applied revisions appear
with controller status. Configuration changes apply between jobs. New claims require
both worker and controller acknowledgement of the current revision. Invalid cloud
settings remain failed/pending and prevent claims.

Execution settings separates current workers from a collapsed **Worker history**.
Stopped/failed workers with no unfinished tasks appear in history; records with
unfinished tasks stay current even after failure. Historical worker state does not
confirm cloud resource termination. The snapshot includes the latest 100 registered
workers plus any older non-terminal workers or workers with unfinished tasks; it
does not delete older database records.

Startup fixes mode, credential chain, region, ASG names, launch template ID, SSM
parameter prefix and instance-type allowlist. These require operator intervention
to change. The authenticated lease holder can append schema fields with defaults
during sync; existing fields and saved values are preserved, and the revision
advances once. Changing existing schema fields or the instance allowlist requires
a new provider enrollment. The UI cannot select arbitrary cloud resources.

## ASG mode

Each ASG instance runs one job. Enroll an ASG with the profile for its guest OS.

- [Linux CI](linux-ci-runner.md) runs Ubuntu jobs with passwordless sudo and a
  job-local Docker daemon.
- [Windows VM](windows-vm-runner.md) runs native jobs as a local administrator
  on Windows Server 2025.
- [macOS VM](macos-asg-runner.md) runs macOS 15 ARM64 jobs as a local administrator
  in a fresh Tart guest on an Apple Silicon EC2 Mac.

Use a dedicated minimum-zero ASG with an explicit, immutable launch-template
version. Linux supports an optional separate Spot ASG with bounded wait and
On-Demand fallback. Install AWS CLI v2 on the controller, pin encrypted
DeleteOnTermination EBS mappings, and scope SSM and IAM permissions to the pool.
The controller waits for the instance to report Online through SSM before it
creates a worker identity. The boot budget from EC2 LaunchTime is 15 minutes
for Linux and Windows and 30 minutes for macOS.

The controller disables IMDS, detaches the guest bootstrap role, deletes the
bootstrap parameter and verifies the disk settings before it arms the claim gate.
A consumed worker retires once its attempt reaches a terminal state. An idle
unused worker drains on pause, replacement or after the configured idle window
when it exceeds demand. Keep the controller running until cloud retirement and
disk deletion are confirmed. See [production deployment](../deploy/production.md)
for rollout and rollback.

## Protocol and verification

Managed control uses JSON POST endpoints under `/-/runner-api/v1`:
`providers/register`, `providers/sync`, `workers/register`, `workers/sync`, and
`workers/:id/drain`. Protocol version is JSON number 1; IDs and revisions are
canonical decimal strings. The original task protocol is unchanged. Registration,
controller, worker and attempt credentials are separate. Workers inherit the
parent's labels, repository grants, pause and revocation. Controllers cannot claim
jobs; workers cannot create workers or configure providers. Requests are limited
to 64 KiB and schemas to 24 fields. Browser settings require admin access and CSRF.

After building assets and native binaries, run:

```sh
moon test --strip -j 1
node scripts/check-package-boundaries.cjs
node scripts/managed-runner-smoke.cjs
node scripts/provider-config-browser-smoke.cjs
```

The lifecycle smoke test uses local Docker/AWS adapters. The browser acceptance
starts the actual MoonHub server and `moonhub-runner` CLI, verifies all nine ASG
fields, saves a new configuration and waits for observed/applied acknowledgement.
Only AWS is simulated in that test. It also checks desktop and mobile layouts,
CSRF/CAS failures, escaped input and one page shell after refresh/navigation.
Set `CHROMIUM_EXECUTABLE` if Chromium is installed outside Playwright's cache.
These tests create no cloud resources. Actual Docker image execution, IAM, AMI
boot and Spot availability need separate deployment acceptance.

## Windows x64 workers

Use [disposable Windows Server 2025 VMs](windows-vm-runner.md) for Windows
ASG capacity. A dedicated Windows PC can separately run a
[standalone Docker provider](windows-runner.md), with supported Windows 11 and
Server 2022/2025 host and image combinations. Register Windows capacity with
`self-hosted,windows,x64`. Jobs without an OS label retain Linux semantics.

```yaml
name: Windows
on: workflow_dispatch
jobs:
  test:
    runs-on: [self-hosted, windows, x64]
    steps:
      - uses: moonhub/setup-moonbit@v1
        with:
          version: latest
      - run: moon test --target js
      - shell: bash
        run: git --version
```

Windows `run` defaults to `pwsh`; explicit `pwsh`, Git Bash `bash`, and `sh` are
supported. JavaScript Node20/Node24 and composite actions use the shared Actions
runtime (assignment versions 5–11); composites may select `pwsh`. PowerShell errors and native command exit
codes fail the step. Paths added through `GITHUB_PATH` use Windows separators.
The existing Action/source/secret/checkout restrictions still apply. Actual
Windows 11 Hyper-V operation requires acceptance on a compatible dedicated PC.

`Windows runner` in GitHub CI builds the native Windows worker and task image on
`windows-2022` and `windows-2025`. It exercises real shells, JavaScript/composite actions, escaping
junctions and detached-child cleanup. Its container acceptance runs three attempts
on one worker, verifies fresh volumes and cleanup before ready, checks cancellation,
and drains the worker. The 2025 instance also builds the generic C++ environment
and runs the pinned original openseek TUI job. This is separate from booting an EC2 AMI and validating
operator-specific IAM/network/registry access, which require deployment acceptance.

## macOS local VM workers

See [macOS VM runner](macos-runner.md) for the Apple Silicon Tart backend,
guest-image preparation, true standby readiness and real HTTP acceptance.
This first slice does not provision EC2 Mac or Dedicated Hosts.
