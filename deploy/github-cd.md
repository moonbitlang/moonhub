# GitHub continuous deployment

GitHub is this repository's development entry point for code, PRs, Issues,
merges and CI. See [CI configuration and cutover](../docs/github-ci.md).

`.github/workflows/ci.yml` runs `Self-check` and `Docker SSH` on GitHub-hosted
Ubuntu 24.04 runners. After both succeed, `CI required` passes and a `master`
push calls `.github/workflows/deploy.yml`. The latter accepts only
`workflow_call`; it has no independent push or manual trigger. The local
reusable-workflow reference and default checkout use the same commit as CI.
PRs cannot deploy. A manual `CI` run defaults to no deployment; select `master`
and set `deploy` to true to deploy after running the complete checks again.
Do not add an independent deployment dispatch or `workflow_run` bypass.

Updated PR runs cancel their obsolete CI. Each non-PR run has its own workflow
concurrency group, while deployment jobs retain the shared `moonhub-production`
group with `cancel-in-progress: false`. New CI cannot cancel an active upgrade.
The production environment remains restricted to `master`, with OIDC permission
only on the deployment job. Self-check and Docker SSH receive read-only tokens.

Production images continue to be built on EC2, published to ECR and deployed
by the existing host script. GitHub runners only run checks and invoke SSM;
there is no production image build or publication job on GitHub.

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
- GitHub environment `production`, allowing deployment from `master` only.
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
fetches `master`, and checks the requested full SHA against its current tip.
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
On a timeout or refusal, let tasks finish and rerun CI on `master` with deployment
selected. If `master` advanced, its newer workflow handles deployment.

An installed standalone DinD controller participates in that switch as well.
Deployment loads the matching image into its dedicated daemon and updates its
binary, startup image and saved provider image together. The tracked `status`
command verifies its release and configuration acknowledgement, so an older
independent executor prevents `MOONHUB_DEPLOY_OK` even when Web/SSH are healthy.
See the local DinD upgrade and recovery procedure in [production.md](production.md).

## Logs, retries and recovery

Use the GitHub Actions run and its deployment job summary to find the SSM
command ID and commit. The complete root-private log stays at
`/var/log/moonhub/deploy-SHA.*`; SSM/Actions receives its last 16 KB to avoid
SSM's output truncation hiding the final verification result.

The SSM document limits execution to one hour. Actions waits up to 75 minutes
for command completion; if Actions is interrupted, inspect the original SSM
command before retrying. Host locking serializes deployments even if the
workflow is canceled. GitHub workflow cancellation does not undo a deployment.

To retry, dispatch `CI` on `master` with `deploy: true`; the complete checks run
before deployment. To stop future deployments, disable `CI` in GitHub Actions.
Inspect the active SSM command before changing a running upgrade. For rollback, use
the matching Web/controller backups described in [production.md](production.md).
Automatic CD refuses non-fast-forward updates, including a rewritten master.

Local clones use GitHub as their development remote. The production checkout
fetches GitHub with its host-only read key. Retiring the outbound mirror must
not revoke this production key. Neither SSH key is an AWS credential.

Validate changes with `node --test scripts/github-deploy-test.cjs` and
`node --test scripts/production-deploy-test.cjs scripts/production-dind-test.cjs`.
These deployment regressions also run in `Self-check`. A real `master` push must also produce
`MOONHUB_DEPLOY_OK:SHA` and matching healthy production image revisions.
