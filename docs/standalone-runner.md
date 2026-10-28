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
and includes the toolchain and step launcher. Use matching controller/task versions.

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
- ASG: instance type from the local allowlist, total worker limit, idle timeout,
  numeric launch-template version, purchase policy and Spot wait timeout.

Saves use compare-and-swap revisions. Desired, observed and applied revisions appear
with controller status. Configuration changes apply between jobs. New claims require
both worker and controller acknowledgement of the current revision. Invalid cloud
settings remain failed/pending and prevent claims.

Startup fixes mode, credential chain, region, ASG names, launch template ID, SSM
parameter prefix and instance-type allowlist. These require operator intervention
to change. A changed schema/allowlist requires a new provider enrollment. The UI
cannot select arbitrary cloud resources.

## ASG mode

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
