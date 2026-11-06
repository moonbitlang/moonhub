# Local macOS VM runner

The first macOS backend uses one dedicated Apple Silicon host and one clean,
booted Tart VM as an execution slot. It does not provision EC2 Mac or manage
Dedicated Hosts. The existing Docker/ASG backends are unchanged; cloud capacity
management can reuse this worker lifecycle after deployment acceptance.

## Readiness and standby

`starting` means that the image is downloading/cloning, the VM is booting, the
guest is unhealthy, or a new clean slot is being prepared. Only a healthy,
unused guest for the current configuration is `ready`. Claims carry `macos` and
cannot consume implicit-Linux or Windows jobs. The UI distinguishes the standby
target, ready capacity and preparation. Preparing instances still consume the
capacity cap; they do not satisfy the ready target.

This local backend fixes `standby_workers` at 1 and executes one job at a time:

1. Clone an operator-owned stopped template or digest-pinned OCI macOS image.
2. Start without graphics, host shares, audio, clipboard or USB passthrough.
3. Verify the root guest service, ARM64/Darwin, runtime and empty job-state root.
4. Acknowledge ready, then claim through the ordinary authenticated HTTP API.
5. Send only the assignment and attempt credential through `tart exec -i`.
6. Run as the guest's dedicated `_moonhub` non-login, non-administrator account.
7. Stop/delete the complete VM, verify inventory, and prepare its replacement.

A guest is single-use even when execution fails. Cleanup failure stops reuse.
Pause destroys idle prepared VMs; drain destroys the prepared slot before its
final acknowledgement. Startup removes only `moonhub-slot-<32 hex>` VMs in the
exclusive backend home. Never share that home between controllers. Use a dedicated
host/service account: Tart has access to all VMs in its configured home.

## Build a guest template

Install verified Tart **2.41.1** separately; `deploy/macos/runtime.json` records
its checksum and source. Tart is an external operator dependency and is not
redistributed by MoonHub; review the selected version's license for your usage.
Use macOS 14+ on Apple Silicon with hardware virtualization available. The template
needs a Tart Guest Agent supporting `--run-rpc`, command-line developer tools,
Git and trusted CA roots. Do not put credentials, signing identities, personal
accounts or provider state in it.

On a matching build Mac, select the production MoonBit version from
`deploy/base.Dockerfile`, then:

```sh
moon update
node scripts/resolve-dependencies.cjs
python3 scripts/build-macos-runner.py
```

The bundle includes the native runner/launcher, checksum-pinned Node20/24, Action
runtime and guest installation script. It copies non-system dylibs and signs local
copies; it does not modify the build host. Supply Xcode in your own template if
jobs need it. MoonBit toolchains remain job-local through `moonhub/setup-moonbit@v1`.

Boot a clean template with Tart and transfer the bundle through `tart exec -i`
(e.g. a tar stream, with no host mount). Run its `install-guest.sh` as root **inside
the VM**. The script refuses a physical host, creates the dedicated job account,
installs the root startup RPC service, disables the public base image's admin account/login
and remote login services, and checks health. Shut it down cleanly; never publish a
running/suspended or previously used execution guest.

For a local template use `--runner-image local:moonhub-macos-v1`; keep the named
stopped template immutable while enrolled. For a registry image use a full
`repository@sha256:<digest>` reference, never a mutable tag. Authentication for
private image pulls must be configured in the dedicated operator environment;
no registry credentials are forwarded to the guest.

## Run the provider

Create a provider with labels `self-hosted,macos,arm64` and repository grants.
Save its registration credential privately, then run from the dedicated host
account (the state/Tart directories must be writable by that account):

```sh
moonhub-runner run --mode tart --name macos-ci \
  --server https://moonhub.example \
  --registration-token-file /path/to/private/registration \
  --state-dir /path/to/private/controller \
  --workspace-root /path/to/private/workspace \
  --tart /path/to/tart --tart-home /path/to/private/tart \
  --runner-image local:moonhub-macos-v1 --prepare-timeout 180
```

`--runner-server` optionally supplies the origin reachable from the guest when
it differs from the host's origin. HTTPS is required normally; `--allow-http` is
only for local acceptance. The VM transport uses no host folder, SSH private key,
provider token or AWS credential. Use `launchd` under the dedicated host account
for a persistent installation; avoid a GUI-login dependency.

Workflows select native macOS explicitly:

```yaml
on: workflow_dispatch
jobs:
  build:
    runs-on: [self-hosted, macos, arm64]
    steps:
      - uses: moonhub/setup-moonbit@v1
        with: {version: latest}
      - run: moon test --target js
```

Shells are Bash/sh; native Node20/24 and composite actions share the existing
Actions runtime (assignment versions 5–7). Docker/service actions and Apple signing credentials are
outside this first slice.

## Acceptance and timing

Ordinary tests exercise protocol, scheduling, image policy and readiness counts.
For real acceptance, use a dedicated Apple Silicon host with a stopped template
prepared as above, build the native CLI and expose the test server only to the
local VM network:

```sh
MOONHUB_MACOS_TART=/absolute/path/to/tart \
MOONHUB_MACOS_TART_HOME=/absolute/path/to/private/tart \
MOONHUB_MACOS_IMAGE=local:moonhub-macos-v1 \
MOONHUB_MACOS_HOST=192.168.64.1 \
moon test --strip -j 1 web/views/pipelines \
  --filter 'macOS VM standby executes real HTTP jobs and replenishes clean capacity'
```

The test uses the real server routes and database, runs success/failure/cancellation
on the same host worker, verifies fresh files/HOME/keychain state, waits for clean
standby after each attempt, and drains. `prepared_ms`, `cleanup_ms`, `attempt_ms`
and first-command latency are printed separately; image cache misses are preparation,
not standby. Measure on the deployment hardware before setting an SLO.

### Initial local measurement

On the first dedicated Apple Silicon acceptance host, a Sequoia 15.7.7 guest
configured with 2 vCPU and 4 GiB took 16.6–17.3 seconds to clone/boot/health-check
from a cached local template. Complete VM deletion took about 1.1 seconds.
The three real HTTP jobs reached their first command in 9.5, 1.6 and 1.8 seconds;
the first included the initial controller configuration acknowledgement. These
are three development samples, not a P50/P95 or deployment SLO. They exclude the
initial image download and do not predict EC2 Mac allocation time.
