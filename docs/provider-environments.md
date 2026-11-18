# Multiple Linux environments in one provider

A standard Linux Docker or ASG provider can offer up to eight execution
environments. Each environment declares one distribution, architecture,
immutable task image and optional capability labels. Provider authorization,
worker count, task CPU/memory limits, pause and revocation remain shared.
Configuring another distribution does not create another worker or ASG.

Supported distributions are Debian 12, Ubuntu 22.04 and Ubuntu 24.04. Every
environment in one provider must use the same architecture (`x64` or `arm64`).
Windows, Tart/macOS and privileged single-use Linux CI retain their existing
single-image configuration. These environments describe container userspace;
they do not select a different host kernel.

## Configure environments

Upgrade the Web service, controller, workers and task images together. The
controller advertises environment protocol 1. Older controllers cannot apply
a provider with named environments, and older workers cannot claim its tasks.
Existing providers without environments keep their current behavior and image.

Open **Site settings → Pipeline providers → Execution settings → Linux
environments**. Add a name, distribution, architecture and task-image reference
ending in `@sha256:` and the full lowercase digest. The image must contain the
updated runner and step launcher, Node Action runtimes and the usual non-root
execution user. Workflows cannot supply arbitrary task-image references.

The first environment becomes the default for generic Linux jobs. Add others
and select a different default explicitly when required. The environment name,
distribution selector and architecture are matching labels; additional labels
can declare tools such as `clang-18`. `ubuntu-latest` is an explicit alias that
an administrator may add to one Ubuntu environment. It is never updated
automatically.

Each image is prepared and inspected on the worker before readiness. The
controller/worker must acknowledge the new configuration revision before new
claims. A probe runs the actual runner in a non-root, read-only, networkless
container, reports environment protocol support, and checks `/etc/os-release`
and executable architecture. A failed image or mismatched declaration prevents
that worker from accepting jobs. A prepared task independently verifies the
selected distribution and architecture before executing repository code.

For ASG workers, keep the host worker executable and bootstrap image compatible
with the launch template's AMI, host libraries and architecture. Named task
images do not replace that host executable. Use registries reachable with the
existing worker identity and normal Docker credentials; no registry credential
is accepted in an environment field. Environment pulls count against the
worker's ordinary readiness/startup budget. Provision cache and disk capacity
for all selected images.

## Select an environment

```yaml
jobs:
  debian:
    runs-on: debian-12
    steps:
      - run: cat /etc/os-release
  ubuntu:
    runs-on: ubuntu-24.04
    steps:
      - run: cat /etc/os-release
```

Scalar distribution selectors request `self-hosted`, `linux`, `x64` and that
exact distribution. Use an explicit label array for ARM64 or extra capabilities:

```yaml
runs-on: [self-hosted, linux, arm64, debian-12, clang-18]
```

All requested labels must match the provider's shared labels plus **one**
complete environment. Labels from different environments are never combined.
Once environments are configured, legacy distribution/architecture labels on
the provider no longer describe task images; those capabilities come from the
selected environment. Generic jobs whose requirements are all shared use the
default environment. Explicit environment requests prefer the default if it
matches, then the earliest saved matching environment.

Claims, eligible queue counts and queue diagnostics use the same matching
rule. A queued job is counted once even when multiple environments match.
One worker still executes one task at a time; ASG capacity limits and standby
targets apply across every environment together.

## Saved execution environment and reruns

The first successful claim captures the environment definition and immutable
image digest on the job. Idempotent claim retries return that definition.
Editing or removing an environment does not change a leased/running task.
Ordinary reruns copy the captured definition, including generic jobs that used
the old default. A newly dispatched run can select the current default/image.

If no authorized provider still offers the saved distribution, architecture,
image and requested labels, the rerun waits with an explicit saved-image
diagnostic. Restore a matching environment or create a fresh run to adopt a new
image. A renamed environment can still run a saved generic/distribution job
when its image and other requirements match. Jobs that explicitly requested
the old environment name continue to require that label.

Pipeline detail and the run JSON API expose the selected environment and image.
No registry credentials or other providers' authorization grants are included.
Provider saves use the existing configuration revision and CSRF checks. Remove
the last environment to return new unpinned jobs to the legacy runner image;
already pinned jobs continue to require a matching named environment.

## Verification

```sh
moon test --strip -j 1 pipeline/environment pipeline/protocol pipeline/workflow pipeline provider runner database
npm run build --prefix js
moon test --strip -j 1 web/views/pipelines web/api
moon build --strip -j 1 . cmd/moonhub-runner cmd/moonhub-diff-worker
node scripts/managed-runner-smoke.cjs --environments
node scripts/provider-config-browser-smoke.cjs --environments
node scripts/check-package-boundaries.cjs
```

The managed-runner smoke uses a Docker adapter to verify actual image selection,
shared capacity, revision preparation and refusal of a mislabeled image. The
browser acceptance runs the real server/controller with an AWS adapter and
checks add/edit/default/remove operations, stale writes, CSRF, escaping and
desktop/mobile layout. Real registry access, image probes and cloud startup
still require deployment acceptance with built task images.
