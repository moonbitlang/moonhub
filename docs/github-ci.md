# GitHub CI and repository cutover

GitHub (`moonbitlang/moonhub`) owns development, Issues, PRs, merges and CI for
this repository. This migration does not remove MoonHub's pipeline, runner,
provider or ASG product features, change business APIs or database schema, or
move historical MoonHub MRs and Issues. The old full-source self-host acceptance
mode has been removed; product functionality uses its existing package tests
and dedicated acceptance scripts.

As of November 4, 2026, the source migration is in
[PR #1](https://github.com/moonbitlang/moonhub/pull/1). The old repository's mirror
and automatic push CI shutdown, plus mirror write-key revocation, are deferred
to the repository administrators for the subsequent cutover. Keep these items
pending until their live state is verified. Production acceptance follows the
protected merge.

## Development PRs

`development` is the default branch. PRs run `Development required` on GitHub-hosted
Ubuntu 24.04 with the production MoonBit pin from `deploy/base.Dockerfile`. It checks
MoonBit warnings, formatting, generated interfaces, package boundaries, the Wasm CLI,
browser asset compilation, TypeScript and CI scripts. It also runs selected native
tests for repositories, the pipeline protocol, parsing and scheduling, runner
platform logic, authentication and key Web routes. Web tests use built browser assets
and the repository and merge request route tests use the native diff worker. A new
run for the same PR cancels its earlier run.

## Full release CI

`.github/workflows/ci.yml` runs on pushes to `codex/release/**` using the candidate SHA.
`Self-check` selects Node 24, installs the exact MoonBit pin and runs
`node scripts/self-check.cjs`. The script runs the checks, native tests and build
with `--strip -j 1`, followed by storage, Docker and runner lifecycle integration
tests. `Docker SSH` runs the separate HTTP, Git SSH and runner image smokes.

`Windows runner` uses a Server 2022 / Server 2025 matrix. Both instances build
the Windows worker and legacy task image and verify shells, Actions, process
cleanup and reusable container workers. Both matrix instances must pass the
single Windows result in the aggregate gate. Application workflows such as
openseek TUI and Desktop run in their own MoonHub repository; the MoonHub
required checks do not fetch or execute openseek source or build its C++ task
environment. The generic build image and opt-in acceptance tools remain available
for dedicated Windows environment validation.
Before building an image, CI probes the pinned local Windows Docker API, starts
the installed Docker service if necessary and waits up to two minutes for API
readiness. Missing services, unsupported daemon platforms and readiness timeouts
fail the job; a Docker CLI on PATH alone does not establish readiness.
See [Windows runner setup](standalone-runner.md#windows-x64-workers) and the
[Windows build environment](windows-build-environment.md).

`macOS runner` builds an ARM64 guest bundle on macOS and tests the native
runtime and prepared-slot lifecycle. Full VM acceptance runs separately on a
dedicated Apple Silicon host; hosted CI cannot substitute for VM isolation tests.

The additional checks run alongside those four jobs, without waiting for
Self-check or sharing its build outputs:

- `.github/workflows/frontend-checks.yml` runs TypeScript (`npm run check --prefix js`)
  and Playwright in the same Ubuntu 24.04 job. The browser job installs and
  verifies the production MoonBit pin, resolves dependencies, builds browser
  assets, checks TypeScript against the generated MoonBit client declarations,
  and builds the native fixture server. The matching locked Playwright version's
  official Noble image supplies Chromium and system libraries; the host runs
  the fixture while the container runs all tests in `js/tests`. This avoids the
  hosted image's unavailable APT mirror. Failed runs upload the HTML report, traces and
  test results for seven days.
- `Build and deployment regressions` in `ci.yml` runs the eight build/deployment
  script regressions (`apt-config`, `base-image`, `deploy-script`, `github-deploy`,
  `moonbit-install`, `production-deploy`, `shared-build`, `shared-host`) and the
  pipeline Compose configuration smoke. The same job runs the Python identity
  transfer test, including its Node interoperability checks. These use disposable
  local fixtures and do not deploy to production.

The frontend workflow has only a `workflow_call` trigger, so it inherits the
caller's commit, PR cancellation and deployment gate without creating duplicate
push/PR runs. Browser tests and build/deployment regressions have independent
runners; the original Self-check still runs its existing checks in order.
Legacy standalone browser smoke scripts and the full Docker pipeline/recovery
end-to-end scripts remain opt-in; these jobs do not invoke them.

## Promote an exact SHA

Both long-lived branches require an up-to-date PR, source-specific checks from
GitHub Actions, linear history and no force pushes, deletions or administrator
bypass. `Development required` protects `development`. `CI required` protects
`production` and accepts only success from all six jobs and a SHA reachable from
`development`.

1. Pin the current `development` commit on a new release branch. Replace the
   example name with a unique release name.

   ```sh
   git fetch origin development production
   release=codex/release/example
   candidate=$(git rev-parse origin/development)
   git merge-base --is-ancestor origin/production "$candidate"
   git push origin "$candidate:refs/heads/$release"
   ```

2. Open a PR from that branch to `production`. Wait for the release branch's full
   CI run for the pinned SHA. If development moves forward while the run is active,
   keep the candidate pinned.
3. Confirm the PR is open, its head is the tested SHA, and the current production
   tip is an ancestor. Push the tested SHA through the PR as a normal fast-forward.

   ```sh
   git fetch origin production
   git merge-base --is-ancestor origin/production "$candidate"
   git push origin "$candidate:refs/heads/production"
   ```

4. Verify GitHub marked the PR as merged with that SHA. The `Production deployment`
   workflow finds successful release CI for that exact SHA and invokes SSM.
   Confirm `MOONHUB_DEPLOY_OK:SHA` and matching Web/SSH health and revision labels.
   See [deployment operations](../deploy/github-cd.md).

## Runtime cutover checklist

These are separate live operations. Source changes do not establish that any
checkbox below is complete. Keep evidence URLs and timestamps with the migration
PR. Do not disable other repositories' pipeline services.

1. Open the GitHub migration PR and obtain successful results for every job,
   including `Frontend checks`, `Build and deployment regressions` and
   `CI required`. Verify a PR update cancels an older running PR CI.
2. Using the existing MoonHub administrator session, disable only
   `compiler/moonhub`'s outbound mirror to GitHub. Wait for in-flight transfers;
   remove GitHub's `moonhub-outbound-mirror` write deploy key, after matching its
   public fingerprint. Preserve `/etc/moonhub/github_ed25519`'s separate read-only
   deploy key. Verify no new mirror delivery can write GitHub refs.
3. Disable **Run push workflows** for only that MoonHub repository. Bring any
   continuing MR work into GitHub PRs before closing the old MRs. Cancel its
   remaining queued/obsolete checks and wait for running tasks to end. Verify no
   new old-repository CI runs appear and another repository's CI still works.
   The MoonHub CLI must be authenticated before any CLI operations; an existing
   browser session does not authenticate it. Do not create broader credentials.
4. The original cutover configured GitHub `master` protection: require PRs with zero approvals, require
   the up-to-date `CI required` check from **GitHub Actions**, enforce for admins,
   and disallow force pushes and deletion. Choose the GitHub Actions app as the
   expected source of the check. Inspect existing repository and organization
   rules before adding a conflicting rule. Confirm direct pushes and bypasses
   are blocked.
5. The original cutover verified that the protected merge reached SSM for
   the checked SHA. The release procedure above now verifies that path on
   `production`. Production image builds occur on EC2.

For local clones, verify `git remote -v` and use GitHub for both fetch and push;
remove obsolete MoonHub push URLs. Existing feature branches can be reused.
Historical MRs and Issues remain available on MoonHub.

## Verification

Run `actionlint .github/workflows/*.yml`, then the
repository's `moon check --deny-warn`, `moon fmt`, `moon info` sequence.
`node --test scripts/github-ci-test.cjs` executes the aggregate shell gate for
all 4,096 combinations of success/failure/cancelled/skipped results, checks deployment
conditions across events, refs and repositories, checks exact-SHA release
verification, version verification and concurrency configuration. The existing self-check and deploy
regressions remain applicable. These local checks do not replace real GitHub
Actions, branch-protection or production acceptance evidence.

For the job dependency and reusable-workflow semantics, see
[GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
and [reusing workflow configurations](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations).

The Windows job also installs a standalone PC provider as a real SYSTEM startup
task and verifies enrollment, task execution, cleanup and identity-preserving
reinstallation without AWS. Windows 11/Hyper-V policy and fail-closed readiness
are covered by deterministic tests; physical Windows 11 acceptance remains a
separate deployment check documented in `windows-runner.md`.
