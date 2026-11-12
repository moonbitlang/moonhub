# GitHub Action execution

MoonHub downloads public GitHub actions referenced as
`owner/repository[/subdirectory]@ref`, resolves the ref to a commit, reads
`action.yml` / `action.yaml`, and runs its declared entry points. There is no
registry of hard-coded implementations for `actions/*`. Newly parsed
`actions/checkout@v4` also takes this path. Historical snapshots without the
`remote` field keep their previous built-in semantics; the explicit existing
`moonhub/checkout@v1` and `moonhub/setup-moonbit@v1` remain available for old workflows.

See [workflow entry compatibility](workflow-entry.md) for runner selectors,
branch/path filters and enforced read-only contents permissions.

This implements the execution foundation for the openseek migration, not full
GitHub Actions service compatibility. See [the migration inventory](openseek-migration.md).

## Supported actions

- Public GitHub repository, tag, branch or full 40-character commit SHA; nested
  action directories and repository-local `./path` actions.
- JavaScript `runs.using: node20` and `node24`, using separate fixed Node binaries.
  `setup-node` can change PATH for workflow scripts without changing the binary
  used to execute another action's declared runtime.
- Composite actions, including nested local/remote actions, `inputs`, `outputs`,
  bash/sh/pwsh steps, per-step environment and conditions.
- JavaScript `pre`, `pre-if`, `main`, `post`, `post-if`, state propagation and
  once-only reverse-order post execution. Normal failures run applicable cleanup;
  cancellation, deadline or lease loss immediately fence execution instead.
- Scalar `with` values, input defaults, `INPUT_*`, `STATE_*`, the supported
  GitHub/Runner environment, and scoped repository secrets in entire `env` or
  `with` values. Input names are case-insensitive for environment delivery.
- `GITHUB_ENV`, `GITHUB_PATH`, `GITHUB_OUTPUT`, `GITHUB_STATE`, multiline file
  commands, bounded local `GITHUB_STEP_SUMMARY`, masking and deprecated
  `set-output` / `save-state` log commands. Unsafe `set-env` / `add-path` fail.
  Log annotations are rendered in logs; there is no annotation UI yet.

Example:

```yaml
name: Node check
on: workflow_dispatch
jobs:
  check:
    runs-on: [self-hosted, linux]
    steps:
      - uses: actions/checkout@v6
        with:
          persist-credentials: false
      - uses: actions/setup-node@v4
        with:
          node-version: '24'
      - id: version
        run: echo "value=$(node --version)" >> "$GITHUB_OUTPUT"
      - run: printf 'Node %s\n' "$NODE_VERSION"
        env:
          NODE_VERSION: ${{ steps.version.outputs.value }}
      - if: always()
        run: echo 'Finished checks'
```

The reference resolves once per action repository/ref within a job and the
resolved SHA is logged. Prefer full commit SHAs for reproducible reruns: a tag
can move between separate jobs or attempts. Private GitHub actions, implicit
refs, arbitrary download hosts, Docker actions and services are not supported.

## Source transport

The authenticated attempt API exports a bounded Git bundle containing only the
pinned source commit. The runner restores it outside the working checkout and
redirects Git fetches for this repository to that local source. Upstream
`actions/checkout` itself performs checkout and cleanup; it receives no provider,
runner or GitHub credential. The source API rechecks authorization and live lease
before and after Git I/O and uses `Cache-Control: no-store`.

Repository symlinks are preserved as Git blobs, including dangling and cyclic
links used by test fixtures. The server never follows them; Git creates the
checkout inside the job container. Submodule gitlinks and `.gitmodules` are
preserved without fetching their repositories on the server. Use an upstream
checkout step to initialize public submodules inside the job:

```yaml
permissions:
  contents: read

jobs:
  build:
    runs-on: [self-hosted, linux]
    steps:
      - uses: actions/checkout@v6
        with:
          submodules: recursive
          persist-credentials: false
      - run: bash scripts/ci/preflight.sh
```

Submodule URLs must be reachable from the job. Public HTTPS URLs need no
repository credential; private or SSH submodules need separately configured
job credentials and host verification. The local-source placeholder does not
authenticate submodule downloads. Prefer absolute HTTPS URLs; submodules in
other private MoonHub repositories do not inherit the parent attempt's source
authorization. Runner-reserved paths remain unsupported, and the legacy tar
source API still rejects symlinks and submodules.

If source preparation is rejected because the source is unsupported or unavailable,
the runner logs the HTTP status and reports a failed job. Expired or invalid attempt
credentials still fence execution as a lost runner.

This transport currently supplies a shallow single-commit checkout only. It does
not supply tags, full history, submodule repository objects or credentials, LFS,
alternate source repositories, arbitrary refs, push authentication, or a GitHub
API token. `github.token` is a noncredential local source placeholder required
by upstream checkout's input contract; it cannot
access either host's authenticated APIs. Actions needing authenticated GitHub APIs
must be treated as migration gaps, not assumed to work from this placeholder.

In versions 5–9, checkout is under `/workspace/repository`; the job HOME and temporary
state are sibling directories, so checkout cleaning cannot delete action runtime
state. Existing versions keep their old directory layout. Actions with no checkout
step retain the previous automatic source extraction behavior.

## Expressions and step status

Server-resolved public references retain their historical nonrecursive behavior.
All other public templates are stored separately and evaluated once at runtime.
A captured branch name or output containing `${{...}}` is never recursively parsed.

The current expression interpreter supports string, number, boolean and null
literals, field / string-key indexing, parentheses, `!`, `==`, `!=`, `&&`, `||`,
and `success`, `failure`, `cancelled`, `always`, `fromJSON`, `toJSON`, `contains`,
`startsWith`, `endsWith`, `format`. Boolean operators short circuit. Contexts are
`github`, `runner`, `env`, `steps`, `needs`, `matrix`, `strategy`, workflow dispatch
`inputs`, and repository `vars`. Composite Actions temporarily use their own `inputs`. See
[dispatch inputs](dispatch-inputs.md) for typed values and the captured event file,
and [repository variables](repository-variables.md) for public configuration snapshots.
See [workflow scheduling](workflow-scheduling.md) for static matrix expansion and
persisted workflow concurrency.
Unknown contexts/functions and malformed expressions fail explicitly at execution.
Unsupported public syntax is not passed literally to the shell.

Step `if` has the implicit `success()` condition unless it explicitly calls a
status function. Failed steps skip subsequent ordinary steps; `always()` / `failure()`
can run cleanup. A failure still makes the job fail after cleanup. `continue-on-error`
records `outcome: failure` and `conclusion: success` in the step context and allows
later steps. Conditional skips are reported as native `skipped` steps and can
complete successfully. Values exported through `GITHUB_ENV` override inherited
workflow/job environment; explicit step environment still takes precedence.
Job-level conditions, declared outputs and direct dependency contexts are supported;
see [job dataflow](job-dataflow.md) for evaluation, persistence and limits.

Use `env` to pass branch names, input or other untrusted text to shell scripts.
As with GitHub Actions, explicitly interpolating that text into `run` can produce
shell code. Secret expressions only occupy an entire `env` / `with` value; they
are not permitted inside scripts, conditions or concatenations. Existing branch,
workflow, authorization and MR secret restrictions still apply.

## Isolation and limits

The native runner remains responsible for process groups, streaming, timeouts,
heartbeats, cancellation and lease fencing. Action code executes as the job's
non-root user. Downloads do not use the server's or provider's credentials.
Action state is kept in an authenticated encrypted file between runtime processes;
the native runner retains its random per-attempt key. The key and internal runtime
configuration variables are not included in action child environments. This reduces
plaintext persistence, not the privileges of deliberately executed repository code.

Limits include 64 MiB compressed / 256 MiB expanded downloads, 10,000 archive
entries, 64 MiB per file, 64 KiB metadata, nesting depth 8, 256 action invocations
per top-level step, 1 MiB per command file, 4 MiB serialized state and 1 MiB total
local summaries. Archive file links may only point directly to regular files inside
the same archive; they are materialized as copies. Unsafe paths, link chains,
duplicate paths and unsupported file types are rejected. YAML aliases and duplicate
keys are rejected. Environment command files
cannot overwrite reserved executor or shell/loader-injection variables.

## Deployment and validation

Upgrade the server, provider/controller and task runner together. Definition
version 2 always uses assignment version 5, including jobs containing only `run`
steps, so environment/output files work without an explicit expression or
action. Older definition version 1 remains readable and runnable; reruns
preserve its saved definition version and legacy assignment selection.
Historical definition-v3 snapshots use assignment version 6 for matrix/strategy
contexts. Definition-v4 snapshots use assignment version 7 for job dataflow with
attempt-bound output storage. Definition-v5 snapshots use assignment version 8
for immutable dispatch input and event contexts. Definition-v6 snapshots use
assignment version 9 for repository variables with persisted configuration
storage. Current definition-v7 snapshots use assignment v10 for scoped [workflow
OIDC identities](workflow-oidc.md) and execution-bound request grants. The
baseline schema includes durable scheduling state; upgrade coordinator, provider
and runner together. See [workflow scheduling](workflow-scheduling.md).

The dependency base installs locked YAML dependencies and pinned Node 20/24
binaries. Its fingerprint includes `runner/actions/package*.json`. Application
image stages continue to run without network access. Rebuild the dependency base
when deploying this change; an older manually supplied base image lacks the runtime.

Offline regression:

```sh
npm ci --prefix runner/actions --ignore-scripts
node --test runner/actions/runtime.test.mjs
moon test --strip -j 1
node scripts/check-package-boundaries.cjs
# After building the updated dependency base:
docker build --target action-runtime-check -t moonhub-actions:check .
docker run --rm --network none --user 10001:10001 moonhub-actions:check
```

Opt-in upstream acceptance (requires public GitHub network access and executes
third-party code inside the test container):

```sh
docker run --rm --user 10001:10001 \
  --mount type=bind,src="$PWD",dst=/work,readonly --workdir /work \
  moonhub-actions:check node scripts/actions-upstream-smoke.mjs
```

The smoke checks pinned-source upstream checkout, setup-node input/output handling
using a preseeded tool cache, and both actions' post handlers. It exercises upstream
Node 24 and Node 20 entry points. It does not test setup-node tool downloads,
cache/artifact services, macOS, Windows or production deployment.

## Artifact v4 service

The original upload/download v4 Actions now use MoonHub's current-run Results and
Block Blob service. Cross-job pattern downloads, overwrite, retention and private
runtime credentials are covered by upstream acceptance. See [Artifact v4](artifact-v4.md)
for deployment, limits, environment bridging and the opt-in acceptance command.

## Cache v4 service and hashFiles

Downloaded cache v4 Actions and JavaScript tool setup cache clients use MoonHub's
Cache Service v2. The server owns immutable branch/MR scopes, archive publication
and lifecycle. Runtime expressions support asynchronous workspace hashFiles()
with Actions glob semantics. See [Cache v4](cache-v4.md) for supported flows,
isolation, limits and original Action acceptance.

Definition-v7 jobs without `id-token: write` retain assignment v9 compatibility;
only OIDC-enabled jobs require assignment v10.
