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

## Checks and deployment

`.github/workflows/ci.yml` replaces `moonhub.yml` and `docker.yml`. It runs on
PRs targeting `master`, pushes to `master`, and manual dispatch. There are no
path filters. `Self-check` and `Docker SSH` run in parallel on GitHub-hosted
Ubuntu 24.04. Self-check selects Node 24, reads the exact MoonBit pin from
`deploy/base.Dockerfile`, installs it with the official Unix installer, and
verifies `moonc -v` before running `node scripts/self-check.cjs`.

The script preserves the index/dependency initialization, check/fmt/info order,
input/interface guard, package boundaries, script tests, frontend build, native
tests and build with `--strip -j 1`, then the managed Docker/ASG lifecycle
acceptance with local adapters (including cleanup failure and stale-worker drain).
Docker SSH keeps
`bash scripts/docker-smoke.sh`. No TypeScript or browser check is added.

`Windows runner` runs on Windows Server 2022, builds the Windows worker and task
image, and verifies shells, Actions, process cleanup and reusable container workers.
See [Windows runner setup](standalone-runner.md#windows-x64-workers).

`CI required` always evaluates all three job results and accepts only successes.
Failure, cancellation or skipping any job cannot pass the gate. Updated PR
runs cancel the older run for that PR. Non-PR runs use separate concurrency
groups, leaving active production deployments running.

Only a successful `master` push calls the reusable `deploy.yml` automatically.
Manual `CI` dispatch defaults `deploy` to false; selecting true deploys only
from `master`, after the same complete CI. The callee has no independent push or
dispatch trigger. Both workflows use the calling commit; no artifact download
or branch re-resolution substitutes unchecked source. OIDC, the `production`
environment, the shared non-canceling deployment lock and the 80-minute timeout
remain in place. Production builds, ECR publication, task draining, backup and
health verification continue on EC2. See [deployment operations](../deploy/github-cd.md).

## Runtime cutover checklist

These are separate live operations. Source changes do not establish that any
checkbox below is complete. Keep evidence URLs and timestamps with the migration
PR. Do not disable other repositories' pipeline services.

1. Open the GitHub migration PR and obtain successful `Self-check`, `Docker SSH`
   and `CI required` results. Verify a PR update cancels an older running PR CI.
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
4. Configure GitHub `master` protection: require PRs with zero approvals, require
   the up-to-date `CI required` check from **GitHub Actions**, enforce for admins,
   and disallow force pushes and deletion. Choose the GitHub Actions app as the
   expected source of the check. Inspect existing repository and organization
   rules before adding a conflicting rule. Confirm direct pushes and bypasses
   are blocked.
5. Merge through the protected PR path. Confirm `master → CI → SSM` succeeds for
   the same SHA, reports `MOONHUB_DEPLOY_OK:SHA`, and verifies Web/SSH health and
   revision labels. Production image builds must still occur on EC2.

For local clones, verify `git remote -v` and use GitHub for both fetch and push;
remove obsolete MoonHub push URLs. Existing feature branches can be reused.
Historical MRs and Issues remain available on MoonHub.

## Verification

Run `actionlint .github/workflows/ci.yml .github/workflows/deploy.yml`, then the
repository's `moon check --deny-warn`, `moon fmt`, `moon info` sequence.
`node --test scripts/github-ci-test.cjs` executes the aggregate shell gate for
all 64 combinations of success/failure/cancelled/skipped results, checks deployment
conditions across events/refs/repositories/results/manual choices, checks version
verification and concurrency configuration. The existing self-check and deploy
regressions remain applicable. These local checks do not replace real GitHub
Actions, branch-protection or production acceptance evidence.

For the job dependency and reusable-workflow semantics, see
[GitHub workflow syntax](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax)
and [reusing workflow configurations](https://docs.github.com/en/actions/reference/workflows-and-actions/reusing-workflow-configurations).
