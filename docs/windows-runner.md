# Standalone Windows PC provider

A dedicated Windows PC can provide one `docker` provider and one reusable worker.
No EC2 instance, AMI, ASG, AWS CLI or SSM Agent is involved. Each job gets a fresh
Windows container and named workspace volume; both are removed before another
job is claimed. The PC and provider identity persist across jobs and restarts.
Use one provider per dedicated Windows Docker daemon: reconciliation owns
`moonhub-pipeline-*` containers and MoonHub-labeled workspace volumes.

## Host and task environment

Supported host policies are:

| Host | Task image | Isolation |
| --- | --- | --- |
| Windows Server 2022 x64 (build 20348) | Server Core LTSC 2022 x64 | `process` |
| Windows 11 x64, Pro/Enterprise with Hyper-V and Containers enabled | Server Core LTSC 2022 x64 | `hyperv` |

The task OS remains Server 2022 on both hosts. Windows 11 does not become a task
image, and the provider does not execute jobs directly on the desktop. Windows
10, Windows ARM64 and other Server releases are not currently allowed by the
backend. See Microsoft's [host/image compatibility matrix](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/version-compatibility),
[isolation modes](https://learn.microsoft.com/en-us/virtualization/windowscontainers/manage-containers/hyperv-container)
and [system requirements](https://learn.microsoft.com/en-us/virtualization/windowscontainers/deploy-containers/system-requirements).

Install a Windows container engine separately. On Windows 11, enable hardware
virtualization, Hyper-V and Containers, reboot as required, and select **Windows
containers** in Docker Desktop if that is the engine you use. Linux/WSL container
mode is rejected. This installer does not install Docker, enable OS features,
accept third-party licenses, switch engine mode or restart the PC.

The provider pins the local `npipe:////./pipe/docker_engine` endpoint. It runs as
SYSTEM, so Docker must be reachable by SYSTEM, not only from an interactive user's
custom context. If your Docker Desktop setup starts the engine only after user
login, capacity is unavailable until then; a startup task does not make the engine
an unattended service. The task retries failed startup every minute. Arrange the
engine's supported startup policy on the deployment PC and verify after a reboot.

Before ready, the worker checks the daemon/image and actually starts/removes a
credential-free container through the chosen isolation path. It also creates a
fresh workspace volume, initializes its ACL and verifies that `ContainerUser`
can create, read and remove files before deleting the probe volume. Missing/broken
Hyper-V, incompatible images, unusable workspace volumes and uncertain cleanup
block readiness and claims.

The worker prepares the next fresh volume before advertising ready and claiming
a job, so initialization does not consume an attempt's start lease. An empty
claim reuses that still-empty prepared volume; a completed job consumes it and the
worker creates a new one before returning to ready. The short initialization container
runs as `ContainerAdministrator` with networking disabled and only that fresh
volume mounted; it grants the container's Users group inherited Modify access.
The task executor and job steps continue to run as `ContainerUser`.
During drain, the worker removes its prepared volume before explicitly reporting
`drained`; a concurrent `ready` heartbeat does not acknowledge that cleanup.

## Prepare the bundle and task image

Build on a Windows x64 machine with Visual Studio C++ Build Tools and the exact
production MoonBit version from `deploy/base.Dockerfile`:

```powershell
moon update
node scripts/resolve-dependencies.cjs
./scripts/build-windows-runner.ps1
```

The bundle includes `install-provider.ps1`, `install-worker.ps1`,
`installation-path.ps1` and `run-provider.ps1`, the native host executable and the existing task runtime.
The deployment PC only needs Docker and the host bundle's `bin` files; it does
not need a compiler, Git, Node, PowerShell 7 or AWS tooling installed globally.
Job tools are supplied by the task image or setup actions.

Build the existing image on a compatible build host. Use the host's isolation:

```powershell
# Windows Server 2022 build host
Docker build --isolation=process -f deploy/windows/Dockerfile `
  -t registry.example/moonhub:runner-windows .tmp/windows-runner
# On a Windows 11 build host, use --isolation=hyperv instead.
```

Publish it through your registry workflow, or preload it on the deployment PC.
An already cached image can be used without a registry pull. Keep matching
server/controller/task versions. Do not put credentials into the bundle or image.
For private image updates, arrange registry access for the service account or
preload the new image into the same local daemon before changing configuration.

## Register and install

In MoonHub's **Pipeline providers**, create a provider with labels
`self-hosted,windows,x64` and the intended repository grants. Save its registration
token to a private file. In an elevated PowerShell session on the deployment PC:

```powershell
& C:/Downloads/moonhub-windows/install-provider.ps1 `
  -Bundle C:/Downloads/moonhub-windows `
  -RunnerImage registry.example/moonhub:runner-windows `
  -Server https://moonhub.example -Name windows-pc-01 `
  -RegistrationTokenFile C:/private/moonhub-registration.txt
```

The installer validates the environment, protects `C:\ProgramData\MoonHub` for
SYSTEM/Administrators, rejects existing trees owned by or writable to other
identities, installs the host binary and creates the
`MoonHubRunnerProvider` scheduled task. It starts at boot without a user password,
has no execution-time limit, permits battery operation and prevents overlapping
task instances. `-NoStart` installs without starting immediately. `-Directory`
and `-TaskName` can change installation locations (the directory must be a direct
child of the system ProgramData directory, outside user-writable parent paths).
Never share the engine between
multiple providers or mix this state directory with an ASG worker installation.
Plain HTTP requires explicit `-AllowHttp` and is only for local acceptance.

The first connection exchanges the registration credential for a persistent
provider identity. Confirm enrollment in execution settings before removing the
original registration file and the private installation's `registration-token`
copy. Preserve `controller/provider-token`, `controller/registered.json` and
`provider.json` across restarts/upgrades. Scheduled-task arguments contain only
launcher/config paths, never tokens. Reinstall refuses a different server/name,
an ASG bootstrap directory, or a running installation.

Workflows select `[self-hosted, windows, x64]`. Server execution settings control
the runner image and per-task CPU/memory limits; changes apply between jobs.

## Operate, upgrade and remove

```powershell
Get-ScheduledTask -TaskName MoonHubRunnerProvider
Get-ScheduledTaskInfo -TaskName MoonHubRunnerProvider
Get-Content C:/ProgramData/MoonHub/provider.log -Tail 100
```

Logs remain in the private installation root. A log larger than 10 MiB is rotated
to `provider.log.1` at the next task start. Startup retries wait for provider lease
handoff and old-worker reconciliation before new claims. A restart does not
create a new provider identity. A sleeping/offline PC cannot supply ready capacity;
check heartbeats and power settings when selecting a dedicated host. If a long
sleep/offline interval caused the server to retire the worker, sync rejection
ends that process and the scheduled task restarts it with a fresh worker identity;
the provider identity stays the same.

To upgrade, pause/drain through MoonHub, wait for the active job and its cleanup,
then stop the scheduled task. Run the same installer with the new bundle, same
server/name/directory/task, and no registration token. Existing controller state
is preserved; the installer refuses to overwrite a running installation. Updating
`RunnerImage` supplies a startup default, while an enrolled provider's saved
server configuration remains authoritative. Change the image there as needed.

```powershell
Stop-ScheduledTask -TaskName MoonHubRunnerProvider
# Re-run install-provider.ps1 with the new bundle, preserving identity arguments.
```

For removal, drain first, stop/unregister the task, then revoke the provider in
MoonHub. Keep or explicitly remove the private installation directory according
to your recovery policy. Stopping a task by force can interrupt a job; the next
startup reconciles stale task containers/volumes before accepting more work.

## Verification

Windows CI runs native policy tests, the existing worker/container acceptance,
and a second acceptance that installs the real standalone scheduled task, enrolls
its provider, executes jobs, verifies volume/container cleanup and cancellation,
and reinstalls while preserving credentials. A deterministic Windows 11 daemon
adapter proves Hyper-V selection and that failed preflight/cleanup never claims.

Hosted CI uses Windows Server 2022. It does **not** prove actual Windows 11
Hyper-V operation. Run the same acceptance on a dedicated Windows 11 PC with
virtualization available, its real daemon and the built bundle/image before
rolling that host configuration into service:

```powershell
$env:MOONHUB_RUNNER_IMAGE = 'moonhub:runner-windows'
node scripts/windows-runner-smoke.cjs --standalone
```

The acceptance creates/removes a temporary scheduled task, protected installation
and firewall rule. Run it only on a dedicated daemon with no other MoonHub tasks.
It checks the real SYSTEM-account path, not just commands run in your login shell.
