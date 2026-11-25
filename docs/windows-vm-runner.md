# Disposable Windows VM runner

Enroll a dedicated On-Demand ASG provider using `moonhub-runner run --mode asg
--windows-vm`. The pool uses prepared Windows Server 2025 x64 AMIs. The external
controller, ASG and provider identity are dedicated to this mode. A registered
provider cannot change into or out of this execution mode.

Use `runs-on: [self-hosted, windows, x64, windows-2025, windows-vm]` for a guest
administrator. The server accepts that selector only on a Windows VM provider
authorized for the repository. **Accept standard Windows jobs** lets the provider
also match its existing Windows labels, including the `windows-latest` alias
for `windows-2025`. Those jobs use an ordinary local account. Both accounts can
create file symlinks on the guest's local disk.

## Image and AWS resources

Build a bundle with [the pinned Windows runner build](windows-runner.md#prepare-the-bundle-and-task-image)
or take the Windows Server 2025 bundle artifact from the successful GitHub CI
run for the deployed revision. Stage it on a clean Server 2025 x64 EC2 builder
with AWS CLI, SSM Agent and EC2Launch v2. Run `install-vm-image.ps1` from the
bundle. It installs the runtime and pinned Visual Studio C++ tools. Verify the
runner starts, remove staging and builder access material, and generalize the
instance with EC2Launch Sysprep before creating an encrypted AMI. Never capture
an enrolled worker or its job state.

Deploy `deploy/windows/vm-pool.yml` with the approved AMI and the required
instance capacity. It creates a separate VPC without connections to production
private networks, an HTTP and HTTPS egress security group with no inbound rules,
an instance-scoped bootstrap role, an explicit launch template and a zero-capacity
On-Demand ASG. Windows uses HTTP to fetch certificate revocation lists for some
HTTPS connections. Keep the launch template's encrypted EBS volumes set to delete
on termination. The template and runtime enforce IMDSv2 and an initial hop limit
of one. Reserve at least two vCPUs and 8 GiB per guest.

The external controller runs under a trusted cloud identity. In addition to
the [ASG controller permissions](../deploy/production.md#iam-responsibilities-and-launch-template-authorization),
it needs `ec2:DescribeIamInstanceProfileAssociations`,
`ec2:DisassociateIamInstanceProfile`, `ec2:ModifyInstanceMetadataOptions`,
`ec2:DescribeInstances`, `ec2:DescribeVolumes` and
`ssm:DescribeParameters`. Scope mutations to the dedicated VM pool, and
`ssm:SendCommand` to its instances and `AWS-RunPowerShellScript`. Scope
`ssm:PutParameter`, `ssm:AddTagsToResource` and `ssm:DeleteParameter` to
the stack's bootstrap prefix. The guest role has only the SSM agent calls and
read access to its own tagged bootstrap parameter.

Enroll the provider with `self-hosted,windows,x64,windows-2025,windows-vm`
and grant the intended repositories. Use a dedicated controller state directory
and provide the stack's ASG, launch template and bootstrap-prefix outputs to
`moonhub-runner run --mode asg --windows-vm`. Select the approved numeric
launch template version, maximum workers and standby count in Execution
settings. Zero standby permits the ASG to scale to zero.

## Claim, verification and cutover

1. The controller starts the worker via SSM. It then disables IMDS and waits
   for AWS to apply the change, disassociates the bootstrap instance profile
   and removes the bootstrap parameter. Only an active controller can arm a
   worker for the current configuration revision. The worker stops SSM Agent
   and removes local cloud caches before preparing the local job account and
   advertising readiness. Windows account creation and security policy setup
   finish before the attempt's startup lease begins.
2. MoonHub marks the worker consumed together with its first successful claim.
   Retrying that claim can recover the same attempt. A different attempt needs
   a fresh VM. A dedicated local account runs the job, and the runner reports
   through the existing attempt API. Treat every credential sent into an
   administrator guest as visible to that job. The controller and cloud
   management identity stay outside the guest.
3. After completion, cancellation, timeout or expiry of the execution lease, the
   controller retires the instance independently of the worker. It checks the
   recorded disks disappear and retains the retirement record if verification
   is incomplete. Restarting the controller preserves that cleanup work.
4. Verify a job using `windows-vm` has administrator rights and can create a
   symlink. Verify a standard Windows workflow resolves a public GitHub action
   tag over HTTPS and runs with an ordinary account. Check that the two attempts
   use different, terminated EC2 instances.
   Check the desired/observed/applied provider revisions and the associated
   EBS volumes and bootstrap parameters. Retry and cancellation should each
   leave the instance retired.
5. For a production cutover, turn on **Accept standard Windows jobs** on the
   new provider and pause the old provider. Verify existing workflows,
   including any explicit Windows version labels they rely on, before revoking
   the old provider. Wait for its active attempts to finish and its ASG to reach
   zero with no remaining instances. Then stop its controller and revoke it in
   Pipeline providers.
