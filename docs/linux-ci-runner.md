# Single-use Linux Docker CI

The Linux ASG profile runs jobs with passwordless sudo and their own Docker daemon
inside a privileged Ubuntu task container. Each EC2 instance accepts at most
one job and is then terminated by the outside ASG controller.

This profile treats the complete worker EC2 as untrusted after job execution
starts. Its EC2 VM boundary, instance IAM boundary and externally enforced VPC
network policy protect other systems. Container privilege is never enabled on
the Web host, its DinD provider or a reusable shared worker.

## Images and enrollment

Build the matching image from a reviewed commit on a dedicated build host:

```sh
docker build --platform linux/amd64 -f deploy/ubuntu/Dockerfile \
  --target ci-runner -t registry.example/moonhub-linux-ci:COMMIT .
```

The image supplies Ubuntu 24.04, sudo, a Docker CLI/daemon, Node 20/24 and the
native runner. Its root entrypoint starts a job-local Unix-socket daemon after
the upstream DinD cgroup initialization, then drops to UID 10001 and executes
the runner as PID 1. Shell steps can use passwordless sudo. The runner disables
process dumps before loading an attempt token. Root task code is nevertheless
able to compromise the worker; neither same-container process protection nor
log masking is a boundary against root.

The per-job daemon shares the job's network namespace and workspace. Thus
`docker run --network host` can reach a service started by an earlier workflow
command, and bind mounts using `GITHUB_WORKSPACE` resolve to the same directory.
`/var/lib/docker` is a separate disposable volume, avoiding overlay-on-overlay
storage. No host Docker socket, host bootstrap directory or provider credential
is mounted into the task. The outside worker removes the task container and
both workspace and Docker-data volumes; instance termination remains mandatory.

Use a separate provider identity, ASGs, launch template, AMI, IAM role and
bootstrap prefix. Grant only the intended repositories. Start its controller
with the ASG options plus `--linux-ci`. The profile is fixed when the provider
enrolls. Select an image labelled `io.moonhub.runner.execution=linux-ci-v1`.

Provision the AMD64 Ubuntu 24.04 pool using `deploy/asg-vm-pool.yml` with
`GuestPlatform=linux` and the approved AMI. Install `deploy/ubuntu/ci-host.sh` as root-owned 0755
`/usr/local/libexec/moonhub-ci-host` in the dedicated AMI. Pre-pull its exact
configured runner image, install the matching native worker and remove build
credentials. Keep IMDSv2 required with hop limit 1 during provisioning, an
encrypted root disk with DeleteOnTermination and no inbound management ports.
Do not use the existing general worker instance profile or merely add new
Ubuntu labels to a generic Debian image.

## Bootstrap and credentials

1. The outside controller registers a new worker identity and creates a
   SecureString parameter tagged with `MoonHubInstanceArn` for that exact EC2.
2. SSM downloads that parameter to `/run/moonhub-runner/bootstrap.json` and
   starts the installed CI host service. The service waits; it cannot claim
   work yet.
3. After confirming SSM bootstrap completion, the controller disables the EC2
   metadata endpoint and waits for `State=applied`. It detaches the bootstrap
   instance profile, removes the parameter and records the disposable EBS
   volumes before it arms the claim gate.
4. Only that live controller can arm the worker's current configuration revision
   through `POST /-/runner-api/v1/workers/:id/isolation`. Worker credentials
   cannot arm themselves. Both worker readiness and the server claim transaction
   require this acknowledgement.
5. The host stops SSM Agent, removes cached ECR login and reads/removes its tmpfs
   bootstrap file. Only the instance-scoped worker token and current attempt
   credentials remain in memory. The server permanently marks the worker draining
   in the first successful claim transaction. Claim retries are idempotent;
   another job cannot be claimed after process restart or identity reenrollment.

Disabling IMDS prevents new metadata retrieval. It does not revoke previously
issued instance-role credentials. Use a dedicated permissions boundary based on
`deploy/ubuntu/ci-worker-boundary.example.json`, substituting the actual account,
region, ECR repository and bootstrap prefix. In addition to identity policies,
that boundary must limit parameter reads to a resource whose
`aws:ResourceTag/MoonHubInstanceArn` equals `${ec2:SourceInstanceARN}`. The role
must have no GetParameters/ByPath/History bypass, parameter writes/tagging,
EC2 metadata modification, role assumption, production storage or controller
permissions. Use the default SSM key unless a narrowly scoped KMS permission is
explicitly required. Validate own-instance reads and denied other-instance reads
with the real policy before enabling a provider. The example boundary does not
grant permissions by itself.

The controller additionally needs scoped `ssm:AddTagsToResource`,
`ssm:GetCommandInvocation`, `ec2:DescribeInstances`,
`ec2:ModifyInstanceMetadataOptions`, `ec2:DescribeIamInstanceProfileAssociations`,
`ec2:DisassociateIamInstanceProfile`, `ec2:DescribeVolumes` and
`ssm:DescribeParameters`. A local retirement journal survives controller
interruption and verifies parameter and storage cleanup after EC2 termination.
The journal is created before publishing bootstrap credentials, so unexpected
Spot interruption or ASG health replacement also triggers cleanup.

## Network and retirement

Configure a dedicated subnet/security group and externally enforced ACL,
firewall or egress gateway before enrollment. Deny access to production private
networks, management endpoints and other workers, including public addresses
where relevant. Permit only the required MoonHub HTTPS endpoint, package/image
registries and dependencies. No inbound access or host-management socket is
needed. Do not rely on iptables inside a root-controlled EC2. Security groups and
NACLs do not filter IMDS; the external metadata-disable gate handles it separately.

The coordinator records single-use consumption atomically when a job is leased,
before any untrusted step runs. The outside controller waits until the attempt
has completed or its fixed lease/deadline expires, then terminates the instance
even if a compromised guest refuses cleanup acknowledgement. It deletes the
bootstrap parameter and its local worker credential. It never waits for the
ordinary idle timeout to reuse a consumed instance. Disk deletion must be checked
through EC2; a database state of drained alone is not cloud cleanup evidence.

An immutable local consumption marker also refuses an accidental worker-service
restart. An unarmed/failed bootstrap remains unable to claim and is retired after
the bounded startup lease. Configuration revisions invalidate prior arming.

Privileged containers can alter global kernel settings such as core-pattern
handling, so this profile is for single-use EC2s only. That supports original
workflow commands such as `sudo sysctl`; these changes disappear with the EC2.
Success reports do not independently establish that arbitrary job code was honest.

## Validation and rollout

Upgrade the coordinator, controller, AMI worker and task image together. Migrate
any reusable ASGs to dedicated one-job pools before deploying the ASG-only
coordinator. Rollback requires the matching database backup.

```sh
moon test --strip -j 1 database provider pipeline runner
moon build --strip -j 1 cmd/moonhub-runner
node scripts/linux-ci-lifecycle.cjs
MOONHUB_LINUX_CI_IMAGE=moonhub-runner:linux-ci-dev node scripts/linux-ci-smoke.cjs
```

The lifecycle fixture runs the real controller with strict AWS/HTTP adapters and
checks bootstrap ordering, external metadata disable before arming, saved image
selection, terminal guest behavior and outside termination. The service tests
exercise authorization, revision changes, idempotent claims and refusal of a
second job. The real container smoke checks apt installation, Docker build/run,
workspace bind mounts, host networking, nested resource limits and cancellation.
Run privileged validation only on a dedicated host or disposable Docker VM.

Before production acceptance, verify the dedicated IAM boundary/network policy,
cold AMI bootstrap, fixed job deadline, success/failure/cancellation and EC2/root
volume/parameter removal. Then execute pinned application workflows without
editing their YAML. Local smoke success alone does not claim production rollout
or complete openseek workflow acceptance.
