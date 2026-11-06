# Standalone MoonHub runner

`moonhub-runner` is a separate native executable. MoonHub owns repository grants,
job scheduling and durable configuration; the runner owns its backend and worker
resources. The server has no AWS dependency. Existing `moonhub pipeline-provider`
and `moonhub runner` commands remain supported. Migration 025 preserves existing
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

Open **Execution settings** beside the provider. The server renders its bounded
schema using generic text, integer and choice fields. No AWS credentials are stored.

- Both modes: runner image, CPU and memory limits per job.
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

For the production Git/SSM deployment, image publication, systemd installation
and rollback procedure, see [production deployment](../deploy/production.md).

Create dedicated ASGs first: one On-Demand group and optionally a separate Spot
group. Both need minimum zero, ordinary instance-count capacity without weights,
and maximum at least the configured total worker limit. Do not attach other
scaling policies, scheduled actions, lifecycle hooks, warm pools or instance
refreshes. Prefer empty groups initially. Enable protection before attaching
existing instances. The controller protects future instances and explicitly drains
workers before scale-in. Health replacement and Spot reclamation can still
interrupt instances.

```sh
moonhub-runner run \
  --server https://moonhub.example --name aws-ci --mode asg \
  --registration-token-file /etc/moonhub-runner/registration-token \
  --state-dir /var/lib/moonhub-runner/controller \
  --region us-west-2 --asg moonhub-ci-on-demand --spot-asg moonhub-ci-spot \
  --launch-template lt-0123456789abcdef0 \
  --instance-types m6a.large,c6a.large,m7a.large \
  --parameter-prefix /moonhub-runner/aws-ci \
  --runner-image registry.example/moonhub:runner
```

Install AWS CLI v2 on the controller (`--aws` overrides its path). It uses its usual
credential chain or instance role. The `runner-controller` Docker target packages
the native CLI; ASG deployments must additionally supply AWS CLI. A host systemd
service is the simplest deployment.

The template pins an AMI and explicit numeric version. The AMI needs Docker, AWS
CLI, SSM Agent, systemd, `/usr/local/bin/moonhub-runner`, and preferably the task
image already pulled. Require **IMDSv2, hop limit 1**. The controller checks that
setting, instance/AMI architecture and task limits before accepting configuration.
Leave at least 512 MiB memory for the host. Jobs run in a bridge network without
privileged mode, the Docker socket, host AWS credentials or application data.
Docker cleanup is not a hostile-tenant security boundary; use disposable EC2
instances per task or stronger VM isolation for untrusted tenants.

Worker roles need SSM managed-instance permissions and read/decrypt permissions
for the bootstrap prefix. Per-instance worker credentials are transported through
SSM SecureString, then downloaded to a root-only file under `/run/moonhub-runner`.
Command history contains names, not credentials. Never share a prefix between
controllers. Provide outbound access to SSM, MoonHub, registries and dependencies.
No inbound management SSH is required. Scope controller IAM to these groups,
instances, template, SSM document and parameter prefix. Required actions include:

- Auto Scaling describe/update, desired-capacity, instance-protection and termination.
- EC2 describe instance types, launch-template versions and images.
- SSM put/delete parameter and send command, plus applicable KMS permissions.
- IAM PassRole/service-linked-role permissions required by the launch template.

Capacity follows eligible queued jobs plus active attempts, capped across both
groups. Starting EC2 instances count as allocated. Spot fallback first requests
Spot, waits the configured timeout, cancels unfulfilled demand, rereads both groups,
and requests only missing On-Demand capacity. AWS allocation races can temporarily
produce surplus capacity; surplus idle workers are drained. Healthy On-Demand
workers are not automatically replaced with Spot.

Idle workers drain after the configured timeout. Instance/template changes, pause,
failure and lost heartbeats also trigger draining. Termination requires zero active
attempts and cleanup acknowledgement, or an expired lost-worker lease. Worker
heartbeats expire after 180 seconds. Each termination decrements ASG desired
capacity, which is reread before scaling. Each EC2 executes one task at a time
using a fresh container and volume. Cleanup failure prevents subsequent claims.

Keep the controller running to scale to zero. Stopping or revoking it does not
destroy infrastructure or guarantee cleanup. Pause and drain first. Manual AWS
termination or Spot interruption can leave orphan parameters; periodically remove
these and corresponding local per-instance token files.

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

Windows supports standalone PCs through `--mode docker` as well as the existing
ASG controller. See [standalone Windows deployment](windows-runner.md) for Windows
11/Server 2022 installation without AWS. Keep Linux and Windows in separate
providers; register the Windows provider with `self-hosted,windows,x64` and
explicitly request those labels in workflows. Jobs without an OS label retain
Linux semantics. There is no `--worker-os` flag: the controller resolves the
existing `--launch-template` plus saved numeric `template_version`, reads its
AMI's `Platform` and `Architecture`, and selects Windows bootstrap automatically
in ASG mode. A standalone provider detects the local Windows daemon directly.
The controller itself may remain on Linux. Claims include the worker's actual OS;
old clients that omit it remain Linux and cannot claim from a Windows provider.

The task image is **Windows Server 2022 x64** (build 20348). Server 2022 hosts
use process isolation; Windows 11 hosts use Hyper-V isolation. The worker checks
the real daemon platform, image and container startup before acknowledging
readiness. Linux Docker daemons cannot run these images.
For ASG deployment, prepare a dedicated AMI with Containers enabled, a Windows Docker Engine, AWS CLI
v2 and SSM Agent. Build the worker bundle on Windows with Visual Studio C++ Build
Tools and the production MoonBit version from `deploy/base.Dockerfile`:

```powershell
moon update
node scripts/resolve-dependencies.cjs
./scripts/build-windows-runner.ps1
docker build --isolation=process -f deploy/windows/Dockerfile `
  -t registry.example/moonhub:runner-windows .tmp/windows-runner
# Publish this image to your registry using its normal authenticated workflow.
./deploy/windows/install-worker.ps1 -Bundle .tmp/windows-runner `
  -RunnerImage registry.example/moonhub:runner-windows
```

The bundle pins and verifies PowerShell 7, Portable Git, Node 20 and Node 24 with
SHA-256 checksums in `deploy/windows/runtime.json`. It includes the native worker,
step launcher and Action runtime. It does not include a compiler: install the
MoonBit toolchain per job with `moonhub/setup-moonbit@v1`, or provide your own
Windows task image with the tools your jobs require. MSVC or other build tools for
job workloads are likewise an image choice. The host needs only the worker's
`bin` directory; never bake credentials or controller state into an AMI.

Create a numeric launch-template version for this AMI, requiring IMDSv2 with hop
limit 1 as on Linux. Set the Windows provider's existing runner-image and template
version settings. Controller IAM must permit `AWS-RunPowerShellScript` in addition
to the EC2/ASG/SSM/KMS operations above. Windows bootstrap downloads the SecureString
to an ACL-protected `C:\ProgramData\MoonHub\private\bootstrap.json` and starts the
`MoonHubRunnerWorker` scheduled task as SYSTEM. The task restarts at boot; its
execution time is unlimited. The bootstrap token never appears in SSM command
history. Worker state and workspace roots default to `C:\ProgramData\MoonHub`.

Each attempt runs as **ContainerUser**, using a new container and named workspace
volume. Windows uses native memory/CPU limits and its `nat` network; Linux-only
read-only-rootfs, capabilities, tmpfs and PID-limit options are not passed to the
Windows daemon. Only the credential-free assignment directory is mounted read-only;
no Docker named pipe, AWS credentials or application data is mounted into the task.
The attempt token is passed through stdin. Steps inherit a small OS environment
allowlist. Windows environment names and workspace containment are case-insensitive;
NTFS device names, alternate data streams and escaping junctions are rejected.
A kill-on-close Windows Job Object owns every step process tree, including detached
children. Normal completion, timeout and cancellation stop that tree. Containers
and workspace volumes are removed **before** the worker acknowledges ready and
claims another job; cleanup failure stops reuse. Instance draining/idle timeout and
Spot fallback retain their existing lifecycle.

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
runtime (assignment versions 5–7); composites may select `pwsh`. PowerShell errors and native command exit
codes fail the step. Paths added through `GITHUB_PATH` use Windows separators.
The existing Action/source/secret/checkout restrictions still apply; macOS workers
and Hyper-V isolation are not part of this implementation.

`Windows runner` in GitHub CI builds the native Windows worker and task image on
`windows-2022`. It exercises real shells, JavaScript/composite actions, escaping
junctions and detached-child cleanup. Its container acceptance runs three attempts
on one worker, verifies fresh volumes and cleanup before ready, checks cancellation,
and drains the worker. This is separate from booting an EC2 AMI and validating
operator-specific IAM/network/registry access, which require deployment acceptance.

## macOS local VM workers

See [macOS VM runner](macos-runner.md) for the Apple Silicon Tart backend,
guest-image preparation, true standby readiness and real HTTP acceptance.
This first slice does not provision EC2 Mac or Dedicated Hosts.
