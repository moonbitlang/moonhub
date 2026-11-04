# GitHub continuous deployment

MoonHub remains the source of truth for code, MRs, Issues and CI. An outbound
push mirror copies its branches and tags to `git@github.com:moonbitlang/moonhub.git`.
Only continuous deployment runs on GitHub; the development workflow is unchanged.
Do not push independent changes to the GitHub mirror.

`.github/workflows/deploy.yml` deploys mirrored `master` updates through SSM.
The existing MoonHub self-check remains in `.github/workflows/moonhub.yml`.
Both that workflow and `docker.yml` are disabled in the GitHub mirror to avoid
duplicate CI or waiting for nonexistent GitHub self-hosted runners. MoonHub's
master merge policy and CI remain responsible for checking source changes.
Deployment jobs share a concurrency group and never cancel an active upgrade.
A manual dispatch on `master` can retry a failed deployment.

## Outbound mirror

In the MoonHub repository's **Settings → Mirrors**, the destination is
`git@github.com:moonbitlang/moonhub.git`. Its independent SSH public key is
registered as a write-enabled GitHub deploy key, and the GitHub host fingerprint
is verified before enabling automatic sync. Force updates and pruning stay off.
Enabling queues the initial full sync; managed pushes and MR merges queue
subsequent updates. See [push mirror behavior](../docs/mirrors.md).

The GitHub mirror receives only branches and tags, excluding private merge and
pipeline retention refs. Check **Sync history** if a MoonHub update has not
appeared on GitHub. No successful mirror transfer means no GitHub push event.

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

The wrapper builds while MoonHub's post-merge CI runs, then waits up to 20 minutes
for active pipeline attempts to finish before invoking the upgrade. The existing
production script still atomically refuses to switch if another attempt started
in the meantime. It then pauses every provider, including any Docker/DinD
provider, waits for cleanup, and restores each original pause state on success
or failure. Ready workers in unchanged secondary providers can remain paused
through the Web update; they do not have to be destroyed. On a timeout or refusal,
let tasks finish and rerun the failed job. If `master` advanced, its newer workflow handles deployment.

## Logs, retries and recovery

Use the GitHub Actions run and its deployment job summary to find the SSM
command ID and commit. The complete root-private log stays at
`/var/log/moonhub/deploy-SHA.*`; SSM/Actions receives its last 16 KB to avoid
SSM's output truncation hiding the final verification result.

The SSM document limits execution to one hour. Actions waits up to 75 minutes
for command completion; if Actions is interrupted, inspect the original SSM
command before retrying. Host locking serializes deployments even if the
workflow is canceled. GitHub workflow cancellation does not undo a deployment.

To retry, rerun the failed GitHub job or dispatch `Deploy production` on `master`.
To stop future deployments, disable this workflow in GitHub Actions. Inspect
the active SSM command before changing a running upgrade. For rollback, use
the matching Web/controller backups described in [production.md](production.md).
Automatic CD refuses non-fast-forward updates, including a rewritten master.

Local clones keep MoonHub as their primary remote. The production checkout
fetches the GitHub mirror with its host-only read key. The mirror's write key
and production's read key are separate; neither is an AWS credential.

Validate changes with `node --test scripts/github-deploy-test.cjs` and
`node scripts/production-deploy-test.cjs`. A real `master` push must also produce
`MOONHUB_DEPLOY_OK:SHA` and matching healthy production image revisions.
