# Workflow containers

Job `container`, `services` and `docker://` steps require assignment v16 and an
administrator-configured Linux CI ASG provider. Its outside controller must arm
each fresh worker at the current configuration revision. The worker is consumed
by one assignment. Labels alone never grant Docker access. Ordinary Docker,
macOS and Windows providers cannot claim these jobs.

```yaml
on: workflow_dispatch
jobs:
  database:
    runs-on: [self-hosted, linux, linux-ci]
    container: postgres:16-bookworm
    services:
      postgres:
        image: postgres:16-bookworm
        env: {POSTGRES_PASSWORD: fixture-password}
        options: --health-cmd "pg_isready -U postgres" --health-interval 5s --health-retries 10
    steps:
      - run: PGPASSWORD=fixture-password psql -h postgres -U postgres -c 'SELECT 1'
      - uses: docker://busybox:1.37
        with:
          entrypoint: sh
          args: -ec 'echo done >> "$GITHUB_STEP_SUMMARY"'
```

Container mappings support `image`, public `env`, `ports` and bounded `options`.
Image/environment expressions use github, inputs, vars, needs, matrix and
strategy contexts. Container expressions omit `github.token`. Use step env or
inputs for secret expressions. Services retain their image user and entrypoint.
A job container runs as root and defaults to `sh`. Its image must contain
the selected shell and command tools. JavaScript actions require a compatible
Linux image and Node's dynamic libraries. The runner mounts its Node executables,
workspace, temporary command/action files, job home and read-only source Git
store. It never mounts the provider's control directory or host Docker socket.

Services share a per-execution network and use their names as DNS aliases. A
service health check must become healthy within two minutes. With no health
check, startup requires the container to be running. Published ports bind only
to loopback; omitted host ports are allocated dynamically. Steps can read
`job.services.<name>.ports['<container-port>']`. A services-only job executes
scripts on the isolated runner and connects to these loopback ports.

Allowed options are CPU/memory limits, shm size and health-check settings.
Services can also override their image user with `--user`.
Host mounts, host networks, privileged flags, daemon addresses and arbitrary
Docker client configuration are rejected. Limits are eight services, sixteen
port mappings per container, sixteen option/value pairs and 64 KiB per plan.

Docker action metadata supports `using: docker`, `image: Dockerfile` (or another
contained Dockerfile path, or `docker://...`), `entrypoint` and `args`. Declared
input defaults, `INPUT_*` values, command files, outputs, env and workspace are
shared with other steps. Metadata pre/post-entrypoint hooks are unsupported.
When metadata is downloaded at runtime, select the explicit `linux-ci` label to
request v16. A job/service container or direct `docker://` step requests it
automatically. Existing saved definitions retain their previous protocol.

Every created container, network and built action image carries the execution
identity. Cleanup runs outside the cancelled step group before completion,
including success, failure, cancellation, timeout and failed startup. Unverified
cleanup reports a lost execution. The provider's outer task and one-use instance
fence remain mandatory, including for unlabelled resources created by scripts.

`scripts/linux-ci-smoke.cjs` exercises real Docker/DinD in the existing Docker SSH
CI job. It verifies service connectivity, action command files and removal of
labelled resources before each terminal completion. It requires a dedicated
validation host or Docker Desktop VM; mocked unit tests do not replace it.
