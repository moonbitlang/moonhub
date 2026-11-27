# GitHub continuous deployment

GitHub is this repository's development entry point for code, PRs, Issues,
merges and CI. See [CI configuration and cutover](../docs/github-ci.md).

A protected fast-forward to `production` triggers `Production deployment`. It
requires a successful full CI run and `CI required` job for the exact push SHA
from a `codex/release/**` branch before calling the reusable deployment workflow.
Manual dispatch on `production` retries deployment and uses the same SHA check.
PRs do not deploy.

Deployment retains the shared `moonhub-production` concurrency group with
`cancel-in-progress: false`. The GitHub environment allows only `production`
and OIDC permission is scoped to the deployment job. Production images are built
on EC2 and published to ECR. GitHub invokes SSM with the checked SHA.

## Retired outbound mirror

Disable this repository's MoonHub outbound mirror to
`git@github.com:moonbitlang/moonhub.git` and remove its `moonhub-outbound-mirror`
write-enabled GitHub deploy key during cutover. Keep the separate production
read-only key below. Also disable automatic push CI only for the old
`compiler/moonhub` repository, migrate active MRs to GitHub PRs before closing
them, cancel remaining checks and wait for running tasks. Other repositories'
pipelines, runners, providers and ASGs remain operational. These runtime actions
require separate verification; editing this documentation does not perform them.

## Provisioned production integration

- AWS account `242126390740`, region `us-west-2`.
- Web instance `i-0deb710f732cea73c` (`moonhub-web`).
- IAM role `moonhub-github-deploy`, trusting only the GitHub repository's
  `production` environment through the existing GitHub OIDC provider.
- GitHub environment `production`, allowing deployment from `production` only.
- Environment variables `AWS_REGION`, `AWS_DEPLOY_INSTANCE_ID` and
  `AWS_DEPLOY_ROLE_ARN`; no stored AWS access keys.
- SSM command document `MoonHub-Deploy`, pinned to version `1` in Actions.
  The role can send only this document to this Web instance and read command
  invocation status. It cannot send arbitrary shell documents or modify IAM.
- Root-owned `/usr/local/sbin/moonhub-github-deploy`, installed from
  `deploy/github-deploy.sh` during setup. Changing that tracked script requires
  an operator to reinstall it through SSM; a source push does not replace it.
- Host-only `/etc/moonhub/github_ed25519`, registered as a read-only deploy key
  for this repository, with GitHub's verified host key in
  `/etc/moonhub/github_known_hosts`.

The host wrapper takes a lock, refuses a dirty checkout or unexpected origin,
fetches `production`, and checks the requested full SHA against its current tip.
The transition wrapper can also fetch `master` before the branch is renamed.
Superseded commits are skipped. It only fast-forwards the production
checkout and invokes `deploy/production.sh upgrade`, preserving the existing
Compose volumes, secrets, backup process and provider/controller safeguards.
It verifies Web/SSH image revision labels and health, the controller and public
login endpoint before reporting success. A deployment failure remains
a failed Actions run; existing upgrade failure recovery still applies.

After GitHub CI passes, the wrapper builds on EC2, then waits up to 20 minutes
for active pipeline attempts (including other repositories) to finish before
invoking the upgrade. The production script atomically refuses to switch if
another attempt started in the meantime. It then pauses every provider,
including any Docker/DinD provider, waits for cleanup, and restores each original
pause state on success or failure. Ready workers in unchanged secondary providers
can remain paused through the Web update; they do not have to be destroyed.
On a timeout or refusal, let tasks finish and retry `Production deployment` on `production`. If
the branch advanced, its newer workflow handles deployment.

An installed standalone DinD controller participates in that switch as well.
Deployment loads the matching image into its dedicated daemon and updates its
binary, startup image and saved provider image together. The tracked `status`
command verifies its release and configuration acknowledgement, so an older
independent executor prevents `MOONHUB_DEPLOY_OK` even when Web/SSH are healthy.
See the local DinD upgrade and recovery procedure in [production.md](production.md).

## Repository lock protocol upgrade

The control-lock and reader-lifetime protocols require a coordinated version
switch for both upgrade and rollback:

1. Stop accepting new SSH connections and terminate all existing SSH sessions.
2. Stop Web and all old-version workers and standalone management commands.
   Verify no old reader or writer survives outside those services.
3. Switch Web and SSH to matching versions, then reopen SSH after health checks.

The deployment scripts stop Web and SSH before replacement; preserve their
backup, draining, locking and health-verification steps. Never mix the previous
name-lock-only SSH implementation with Web cleanup that expects ID-based reader
locks, or the new SSH implementation with old cleanup. Old
`moonhub-write.lock` writers also cannot coexist with `.locks` writers. No database
or physical-directory migration is needed. Preserve `<repository-root>/.locks`,
including permanent `repository-readers/<id>.lock` files, across upgrades,
backups, cleanup and same-name rebuilds; never delete control files to clear a lock.

## Logs, retries and recovery

Use the GitHub Actions run and its deployment job summary to find the SSM
command ID and commit. The complete root-private log stays at
`/var/log/moonhub/deploy-SHA.*`; SSM/Actions receives its last 16 KB to avoid
SSM's output truncation hiding the final verification result.

The SSM document limits execution to one hour. Actions waits up to 75 minutes
for command completion; if Actions is interrupted, inspect the original SSM
command before retrying. Host locking serializes deployments even if the
workflow is canceled. GitHub workflow cancellation does not undo a deployment.

To retry, dispatch `Production deployment` on `production`. If the full release CI
needs to be rerun, rerun it from the exact candidate in Actions. To stop future
deployments, disable `Production deployment` in GitHub Actions.
Inspect the active SSM command before changing a running upgrade. For rollback, use
the matching Web/controller backups described in [production.md](production.md).
Automatic CD refuses non-fast-forward updates, including a rewritten production branch.

Local clones use GitHub as their development remote. The production checkout
fetches GitHub with its host-only read key. Retiring the outbound mirror must
not revoke this production key. Neither SSH key is an AWS credential.

Validate changes with `node --test scripts/github-deploy-test.cjs` and
`node --test scripts/production-deploy-test.cjs scripts/production-dind-test.cjs`.
These deployment regressions also run in `Self-check`. A real `production` push must also produce
`MOONHUB_DEPLOY_OK:SHA` and matching healthy production image revisions.
