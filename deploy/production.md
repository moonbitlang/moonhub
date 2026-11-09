# Production: Git checkout + SSM + standalone ASG

This is the current production deployment path. Web/SSH run in Compose on
`moonhub-web`; a host systemd service runs the standalone ASG controller. Task
containers for the ASG provider run on disposable worker EC2 instances. An
existing Docker/DinD provider can coexist on the Web host; upgrades preserve its
original pause state as well. The `moonhub-legacy` SSH alias refers to the retired
host.
Do not add a management SSH alias or open port 22 on the new host: its port 22
is the application's Git transport. Use AWS Systems Manager Session Manager
or Run Command with the existing instance role.

Source stays in `/srv/moonhub/source`, with `origin` pointing to
`git@github.com:moonbitlang/moonhub.git`. GitHub owns this repository's code,
PRs, merge gate and CI. After full CI passes on `master`, GitHub Actions invokes
the restricted SSM deployment document using OIDC. Production images still build
on the Web EC2 host and publish to ECR through the existing upgrade path. A host-only read-only deploy
key fetches the source; see [GitHub continuous deployment](github-cd.md).
The local MoonHub bare repository is retained as the `moonhub` remote.
ECR distributes the built
Runner image to EC2 workers; it does not transport the source checkout.

## Existing-host setup

Requirements on the Web host: Docker Engine with Buildx/Compose, Bash, Git, jq,
Python 3, curl, OpenSSL, AWS CLI v2 and SSM Agent. Use the EC2 instance role, not
copied personal AWS credentials. Provision dedicated ASGs, worker instance profile
and scoped controller IAM as described in [standalone runner](../docs/standalone-runner.md).
Keep ASG minimum zero, maximum one initially, desired zero and scale-in protection
enabled. Workers need outbound network access and no inbound management ports.

Copy `deploy/production.env.example` to the Git-ignored `deploy/production.env`
and restrict it to mode 0600. Set the real launch-template ID and preserve the
existing Compose project name, data/SSH-key volume names, bootstrap secret bind,
SSH-import bind, HTTP bind and Git SSH port. Do not recreate or rename data volumes.
The dedicated provider is named `asg`, labels are `self-hosted,linux,moonhub-build`,
and repository scope is `all` (current and future repositories). Enrollment preserves
existing provider grants; verify an existing provider already has all-repository
scope in Site settings. Never replace its enrolled identity just to change grants.

From an SSM session (or the same commands in `AWS-RunShellScript`):

```sh
cd /srv/moonhub/source
./deploy/production.sh checkout master
./deploy/production.sh build
./deploy/production.sh publish
```

The build reads only `git archive HEAD` from this server checkout, uses a dedicated
2 CPU / 4 GiB BuildKit with no host Docker socket or application volumes, and
labels Web, Runner and controller images with the exact commit. It requires
12 GiB of free headroom and stops the builder afterward. `publish` uploads only
the commit-tagged task image to the configured ECR repository. Immutable ECR tags
are recommended. The operator settings file and credentials are excluded from builds.

## Worker network and public addresses

Workers accept no inbound connections; SSM and task traffic are outbound. They
can use private addresses only when a NAT/proxy or equivalent egress arrangement
provides every required destination. SSM/ECR endpoints alone do not provide
Internet access for Ubuntu packages, MoonBit and npm dependencies.

The current production VPC has an Internet Gateway route and no NAT or VPC
endpoints. Its disposable workers therefore use automatically assigned public
IPv4 addresses for outbound connectivity. Do not simply disable public addresses
on that template: provide and verify another egress path first. The private-address follow-up is tracked in Issue #2,
“Run ASG workers without public IPv4 addresses”. No Elastic IP is
reserved for workers; termination releases their public addresses. Keep worker
security-group inbound rules empty.

## Launch template and initial enrollment

The committed `worker-bootstrap.sh` installs Docker/AWS CLI/SSM, pulls the pinned
task image and extracts the matching worker binary. Ubuntu 24.04 amd64 is supported
by this bootstrap; use a prebuilt AMI for faster starts. The source template must
have an encrypted disposable root disk, the dedicated worker role/security group,
and IMDSv2 required with hop limit 1.

Before initial enrollment, create version 1 of an image-pinned template, based on
the existing dedicated template. This command uses the operator's AWS permissions:

```sh
python3 deploy/asg-template.py --region us-west-2 \
  --template lt-EXISTING --source-version 1 \
  --new-name moonhub-runner-production-COMMIT \
  --image ACCOUNT.dkr.ecr.us-west-2.amazonaws.com/moonhub-runner:COMMIT
```

Write the returned template ID to `MOONHUB_LAUNCH_TEMPLATE` in `production.env`.
The image tag must be the 12-character Git commit from the build. Initial enrollment
uses template version 1. On later releases omit `--new-name` to add a version to
the same template; select the returned numeric version and new Runner image in
**Pipeline providers → Execution settings**. Those saved settings are authoritative
after enrollment; changing CLI defaults does not overwrite them. Keep the template
ID and instance-type allowlist stable for an enrolled provider.

## Upgrade and verification

```sh
./deploy/production.sh upgrade
./deploy/production.sh status
```

Upgrade builds and publishes before pausing claims. At the switch boundary it
checks for active attempts and pauses every non-revoked provider in one database
transaction. This includes a Docker/DinD provider running alongside the ASG
controller. Active attempts still refuse the upgrade without interrupting tasks.
The script records each provider's original pause state and restores them together
after the switch; a provider that was already paused stays paused.

If the installed standalone controller binary and systemd settings match the new
build, an enrolled provider can keep idle workers and nonzero ASG capacity. The
script stops the controller before the temporary pause, preventing that pause from
triggering worker retirement. Saved execution settings must already be applied.
The script waits for task cleanup with claims paused. Other unchanged providers
can keep ready workers only while paused and with their configuration applied.
Busy or starting workers in those providers continue to block the switch. The
controller restarts only after the original pause state has been restored. A successful upgrade starts the
controller even if it was inactive beforehand, so idle retirement can resume.
New commit-tagged bootstrap Runner image defaults do not change an enrolled
provider's saved execution settings.

An independently installed `moonhub-dind-controller.service` is upgraded in the
same switch. The script reads its existing unit to preserve its server, provider
identity, dedicated socket, private paths and resource limits. Set
`MOONHUB_DIND_CONTROLLER_SERVICE` for a differently named local unit. Dynamic
ExecStart values and systemd drop-ins are rejected before pausing production;
use a literal unit so the managed binary and socket can be verified.

Before pausing claims, the script loads the commit-tagged task image into the
dedicated DinD daemon and verifies its revision label. After the atomic pause,
it stops the local controller, refuses leftover task containers and retires that
stopped controller's workers and lease. It backs up the unit, binary and private
state under `controller-TIMESTAMP-COMMIT/dind`. The switch installs the matching
controller binary, updates both the unit's image default and the enrolled
provider's saved `runner_image`, preserving other execution settings and grants.
The original pause state is restored before the new controller starts.

DinD release images have a separate retention policy from
`MOONHUB_BACKUP_KEEP` (which limits complete backup bundles). After successful
controller verification, the deployment records the current and previous
successful image in the controller state's private `deployed-images.json` and
removes older `moonhub-runner:COMMIT` tags from that dedicated daemon. Revision
labels must match the tags. Images referenced by any container, the saved current
image and the controller's startup image are protected even if this temporarily
keeps more than two images. Other repositories, volumes, workspaces and host
recovery images are never pruned by this policy. An idempotent retry preserves
the previous successful image; a failed import or switch never advances the journal.

Before importing, matching retention state also permits removal of obsolete
releases while preserving both successful versions and any already loaded
candidate. The first upgrade without a journal, or after an operator changes
the saved image, conservatively keeps existing recovery images until a new
release succeeds. Repeating the current release without a journal does not
guess which previous image can be removed.

The import preflight resolves the daemon's actual data directory through its host
container mount, including a bounded loop filesystem. Root-disk free space alone
is not sufficient. It requires twice the candidate image's uncompressed size
(temporary archive plus extraction), another 1 GiB of task headroom, and 65,536
free inodes. Uncompressed size is the sum of byte sizes from
`docker image history --no-trunc --human=false`; containerd's `image inspect`
`Size` may also include compressed blobs and must not be used as an unpacked
size estimate. Unavailable or invalid layer sizes refuse the import. An already
loaded matching release is reused and only needs the
headroom reserve. It logs the actual path, available space and requirements;
insufficient capacity stops before claims are paused or Web is changed. If
protected images or task data still prevent an import, explicitly enlarge that
dedicated filesystem or perform scoped operator cleanup; do not bypass the check
or use an account-wide Docker/volume prune. `production.sh status` also reports
and checks this storage reserve without deleting any images.

Legacy hosts may still have an 8 GiB `/srv/moonhub/dind.ext4` even though
`setup-shared-host.sh` provisions 12 GiB for new installs. The first retained-image
upgrade has no successful-release journal, so it cannot safely guess which old
image is the previous successful release. If its capacity check fails, inspect
the exact DinD mount and image sizes before retrying. Existing root-disk capacity
does not enlarge a loop filesystem. An operator can grow the backing file and
its associated loop device, then grow the mounted ext4 filesystem to the documented
12 GiB, after verifying their association and leaving at least 20 GiB of root
headroom. Preserve existing contents; never rerun `mkfs` on that backing file.
Afterward dispatch CI on `master` with deployment selected. The successful upgrade
initializes retention from the saved running image and prunes older releases.

Upgrade and `status` check the installed binary, unit image, DinD image revision,
controller lease and observed configuration. An unpaused provider must also have
applied the new configuration and reported a ready or busy worker. Verification
waits up to `MOONHUB_DIND_START_TIMEOUT` seconds (default 180, maximum 600).
An operator-paused provider stays paused and only needs to observe the new
configuration. If replacement or verification fails after stopping DinD, the
script leaves that provider paused, restores the other providers' original pause
states and reports the recovery backup. It must not resume an incompatible old
controller against a newly upgraded Web server.

When the controller binary or settings change, the script automatically pauses the
provider and leaves the old controller running to drain workers and both ASGs to
zero before replacing it. Pause triggers draining without waiting for idle timeout.
The wait is bounded by `MOONHUB_PRODUCTION_DRAIN_TIMEOUT` (default 600 seconds,
allowed range 0–3600). A refused or failed upgrade attempts to restore the original
pause state and restarts a previously running controller, including one that was
waiting for systemd's automatic restart delay.

The controller backup contains `provider-state.json`, written before the pause
transaction commits. New journals contain the original state of every paused
provider; recovery also accepts older single-provider journals. If Web is unavailable
and automatic restoration fails, the script reports this journal's path and exits unsuccessfully. Restore Web health,
then restore the original pause state using that journal (substitute the real
Compose project and backup path):

```sh
docker exec -i --user git PROJECT-web-1 node --no-warnings - restore \
  "$(cat /path/to/controller-backup/provider-state.json)" \
  < deploy/production-provider-state.cjs
```

The existing `deploy.sh` creates a complete Web/SSH data and image backup before
the switch. The production wrapper additionally saves the old controller unit,
binary, private state directory and operator settings under a separate
`controller-TIMESTAMP-COMMIT` backup. It preserves controller enrollment state and
installs a systemd unit with a 65-second restart delay for the 60-second server lease.
New registration tokens are written only to root-private files and passed to the
application over stdin. An enrolled provider does not require its original token.

After upgrade, verify the provider has its original pause state, Web/SSH health,
controller active status, all-repository grants and observed/applied configuration
revisions. Trigger a real production pipeline through the MoonHub CLI; verify an
ASG launches a worker, the worker executes and reports the task, cleanup succeeds,
and idle capacity returns to zero. Use a dedicated product acceptance repository
with a supported MoonHub workflow, rather than this source repository's GitHub
CI workflow. Record the result with the GitHub deployment run or change PR.

## Rollback

Pause the provider and wait for active work and both ASGs to drain to zero. Stop
`moonhub-runner-controller.service`. Restore the matching Web/SSH bundle using
`deploy/deploy.sh restore BACKUP --replace`. Restore the controller unit, binary,
private state and settings from the corresponding controller backup; the Web
database and controller token state must match. Run `systemctl daemon-reload`
and start the controller. Keep old ECR images and launch-template versions until
rollback is no longer needed. Controller backups contain credentials: keep 0700
directories and 0600 files. Web backup retention does not delete controller backups;
remove obsolete controller bundles manually after verifying a newer recovery point.

When an independent DinD controller is installed, pause its provider and wait for
its attempts to finish, then stop its systemd service too. Restore its binary,
unit and private state from the matching `dind/` backup alongside Web. If only the
saved image needs recovery, while that provider is paused and has no active
attempts, pass `dind/image.json` to the host helper:

```sh
docker exec -i --user git PROJECT-web-1 node --no-warnings - restore-image dind \
  "$(cat /path/to/controller-backup/dind/image.json)" \
  < deploy/production-dind-state.cjs
```

This restores only the image, preserves other current settings and advances the
configuration revision. It refuses a different provider identity or an image
changed since the backup. Keep the provider paused until the restored Web,
controller and task image are compatible; restore its original pause state from
`provider-state.json` and start the matching controller afterward.

## IAM responsibilities and launch-template authorization

There are three different AWS identities. Do not assume that a successful command
from an operator laptop proves that the production controller can run it.

| Identity | Required access |
| --- | --- |
| Provisioning operator | Create/update dedicated ECR, roles and instance profile, security group, launch templates and zero-capacity ASGs; install the scoped controller/worker policies. |
| Web instance role / controller | Describe instance types, AMIs, launch templates (both DescribeLaunchTemplates and DescribeLaunchTemplateVersions) and ASGs; update the dedicated ASGs, set capacity/protection and terminate drained instances; put/delete only its bootstrap parameters; send the bootstrap SSM document only to tagged Runner instances; pass the dedicated worker role to EC2. Image publication additionally requires ECR push access. |
| Worker instance role | SSM managed-instance connectivity; get/decrypt only its bootstrap parameter prefix; authenticate to ECR and pull only the Runner repository. |

ASG configuration also validates permission to use the selected launch template.
Grant the controller the required EC2 launch authorization for that template's
AMI, security groups, subnets and newly created instance/network-interface/volume
resources, together with applicable tag-on-create permissions. Scope PassRole to
the worker role. Recheck the policy when changing template resources; permission
for one template does not automatically authorize a replacement template.

Use instance roles on both hosts. Never place personal credentials in user data,
`production.env`, Docker build arguments or the Git checkout. Bootstrap parameter
values and local controller/worker token files are credentials; do not paste them
into logs or a support ticket.

## Operational checks

Run host commands in an SSM session on `moonhub-web`:

```sh
cd /srv/moonhub/source
git status --short --branch
git rev-parse HEAD
./deploy/production.sh status
systemctl show moonhub-runner-controller.service \
  -p ActiveState -p SubState -p ExecMainStatus
journalctl -u moonhub-runner-controller.service --since '-10 min' --no-pager
curl --fail --silent --output /dev/null \
  https://moonhub-dev.mooncakes.io/-/login
```

`active/running` alone is insufficient: in Execution settings, the desired,
observed and applied configuration revisions must agree and status must be applied.
Check both dedicated ASGs, including instances that have not finished booting:

```sh
aws autoscaling describe-auto-scaling-groups --region us-west-2 \
  --auto-scaling-group-names moonhub-runner-on-demand moonhub-runner-spot \
  --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Desired:DesiredCapacity,Instances:Instances[].{Id:InstanceId,State:LifecycleState,Health:HealthStatus}}' \
  --output json --no-cli-pager
```

Use the authenticated MoonHub CLI from the operator machine for task acceptance:

```sh
moonhub auth status --json
moonhub ci run --repo OWNER/ACCEPTANCE_REPO --branch master \
  --workflow .github/workflows/acceptance.yml --json
moonhub ci list --repo OWNER/ACCEPTANCE_REPO --json
moonhub ci view RUN --repo OWNER/ACCEPTANCE_REPO --json
moonhub ci logs RUN --attempt ATTEMPT --after 0 --repo OWNER/ACCEPTANCE_REPO --json
```

Substitute an existing acceptance repository, branch and eligible
`workflow_dispatch` path. Product CI acceptance uses the MoonHub CLI; source
development, PRs and deployment status use GitHub.

Record the deployed source SHA, ECR image digest, numeric template version, backup
locations, successful run/attempt and final zero-capacity observation with the
GitHub deployment run or change PR.
A queued check or a registered worker alone does not establish task execution.
Keep **Standby workers** at `0` when validating scale-to-zero. A positive value
intentionally retains idle capacity, subject to Maximum workers. Keep the
controller running during the configured idle timeout (the enrollment default is
600 seconds; production uses 60 seconds to reduce idle cost) and confirm both
desired capacity and instance counts return to zero.

## Post-validation resource cleanup

Keep the controller running after a successful check. First verify the task
container and its `io.moonhub.pipeline.workspace=1` volume have disappeared. Wait
for the configured idle timeout, then verify both dedicated ASGs have desired
capacity zero **and** no instances. Confirm the terminated workers' disposable
root volumes were deleted; an empty queue alone is not a cleanup result.

Inventory only the resources created for this rollout. Delete unused experimental
launch templates after checking that neither ASG nor the saved provider configuration
references them. Remove bootstrap parameters and local per-instance token files
only for confirmed terminated instances; the controller normally deletes its
parameter on successful retirement. Use `describe-parameters` for inventory rather
than printing parameter values. Never delete controller enrollment credentials.

If a temporary AMI, snapshot, EBS volume, EIP, bucket or test instance was created,
record its ID and remove it when no deployed resource or recovery procedure needs
it. Do not run account-wide cleanup or delete unrelated untagged resources. Keep
the deployed ECR image and a deliberate recovery image; remove only confirmed
unused experimental images. Preserve the operational ASGs, worker role/profile,
networking and active launch template so future queued jobs can start normally.

Record deleted resource IDs and the final capacity/disk/parameter checks in the
GitHub deployment run or change PR. Verify Web health and controller status again
after cleanup. Remove temporary root-private administration sessions/scripts used
during rollout.

## Troubleshooting observed during production rollout

| Symptom | Check / resolution |
| --- | --- |
| Buildx stops with `additional privileges requested` for the temporary snapshot | Use the committed production entry point, which grants `fs.read` only for its own temporary snapshot. Do not disable filesystem entitlement checks globally. The running services remain untouched. |
| Controller/worker exits immediately when its persistent directory already exists | Use the fixed runner version that accepts existing directories. Keep enrollment state and private tokens; deleting them can disconnect the enrolled identity. The lifecycle regression test covers pre-created directories and preserves their contents. |
| Controller runs, observed revision advances, applied revision remains zero / status is failed | Check AWS authorization and resource constraints using the Web instance role. Controller logs deliberately omit AWS response bodies to avoid leaking secrets. |
| ASG update reports `not authorized to use launch template` | Check EC2 launch/template permissions, PassRole, template resource ARNs and tag permissions, not only `autoscaling:UpdateAutoScalingGroup`. Verify from the production instance identity. |
| Task is lost before its first log on a root-run host Worker | Use the version that explicitly sets the credential-free manifest to 0444 inside its 0700 host directory. Docker preserves host file ownership/mode; a 0600 root-owned manifest is unreadable to the non-root task UID. The credential still arrives only over stdin. |
| EC2 exists but worker is not ready | In SSM, inspect `cloud-init status --long`, `/var/log/cloud-init-output.log`, Docker image pull and `journalctl -u moonhub-runner-worker`. User-data installation may take several minutes. Verify outbound SSM/ECR/MoonHub connectivity and the worker role. Do not print bootstrap JSON. |
| Upgrade refuses active attempts or times out draining workers/ASGs | Let active tasks and cleanup finish, then retry. The script pauses/restores the provider automatically. Controller changes require full drain; unchanged controllers permit paused idle workers. Check controller/AWS health if draining stalls; do not force-stop tasks or lower desired capacity around protected busy instances. |
| Upgrade reports provider pause restoration failure | Recover Web health and restore the original state with the reported `provider-state.json` journal as described above. The upgrade exits unsuccessfully if restoration fails. |
| Idle workers exceed `idle_seconds` with `standby_workers=0` | Check `systemctl status moonhub-runner-controller.service` and its journal on the Web host. The controller performs ASG retirement; worker heartbeats alone do not prove it is running. Recover the controller service, then allow a reconciliation cycle to drain and terminate idle instances. |
| Restart temporarily cannot acquire the controller lease | Wait for the previous 60-second lease to expire; the systemd restart delay is 65 seconds. Do not create another provider or replace credentials. |
| Runtime image/template changes do not take effect after changing CLI flags | Saved server configuration wins after enrollment. Update the matching Runner image and numeric template version in Execution settings, then wait for acknowledgement. |

Deployment changes and this runbook belong in the same GitHub PR. Update both
whenever an operational decision changes, and distinguish completed acceptance from pending
checks in the PR; do not treat provisioning success as end-to-end verification.
