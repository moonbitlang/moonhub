# Production: Git checkout + SSM + standalone ASG

This is the current production deployment path. Web/SSH run in Compose on
`moonhub-web`; a host systemd service runs the standalone ASG controller. Task
containers run on disposable worker EC2 instances. No DinD/provider containers
run on the Web host. The `moonhub-legacy` SSH alias refers to the retired host.
Do not add a management SSH alias or open port 22 on the new host: its port 22
is the application's Git transport. Use AWS Systems Manager Session Manager
or Run Command with the existing instance role.

Source stays in `/srv/moonhub/source`. Fetch the deployment branch directly from
Git and fast-forward a clean checkout. For the self-hosted repository, an origin
pointing to the existing local bare repository is sufficient; no source archive
upload, S3 bucket or new source transport is required. ECR distributes the built
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
./deploy/production.sh checkout codex/standalone-runner
./deploy/production.sh build
./deploy/production.sh publish
```

The build reads only `git archive HEAD` from this server checkout, uses a dedicated
2 CPU / 4 GiB BuildKit with no host Docker socket or application volumes, and
labels Web, Runner and controller images with the exact commit. It requires
12 GiB of free headroom and stops the builder afterward. `publish` uploads only
the commit-tagged task image to the configured ECR repository. Immutable ECR tags
are recommended. The operator settings file and credentials are excluded from builds.

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

Upgrade builds and publishes before stopping anything. It refuses active attempts.
For an enrolled provider, pause it in Site settings, allow workers to drain/terminate,
and leave the controller running until the ASGs reach desired zero. The script stops
the controller and checks that no undrained workers or active attempts remain before
switching Web. A refused upgrade restarts a previously running controller.

The existing `deploy.sh` creates a complete Web/SSH data and image backup before
the switch. The production wrapper additionally saves the old controller unit,
binary, private state directory and operator settings under a separate
`controller-TIMESTAMP-COMMIT` backup. It preserves controller enrollment state and
installs a systemd unit with a 65-second restart delay for the 60-second server lease.
New registration tokens are written only to root-private files and passed to the
application over stdin. An enrolled provider does not require its original token.

After upgrade, resume the provider if it was paused. Verify Web/SSH health,
controller active status, all-repository grants and observed/applied configuration
revisions. Trigger a real production pipeline through the MoonHub CLI; verify an
ASG launches a worker, the worker executes and reports the task, cleanup succeeds,
and idle capacity returns to zero. Keep the MR open until this acceptance passes.

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
