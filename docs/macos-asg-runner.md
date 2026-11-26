# Disposable macOS ASG runner

Enroll a dedicated `--mode asg --macos-vm` provider. Each worker is one Apple
Silicon EC2 Mac that boots one clean Tart macOS 15 ARM64 guest. Only one job can
claim that worker. Both the guest runner and the job steps run as `_moonhub`,
a member of the guest's `admin` group with passwordless `sudo`. Workflows select
`macos-15` or use `[self-hosted, macos, arm64, macos-vm]` to require this ASG
profile. Add `macos-latest` to the provider labels if that alias should select
the same macOS 15 image.

## Prepare the guest and host AMI

1. Build the ARM64 [macOS runner bundle](macos-runner.md#build-a-guest-template)
   from the selected release or use its `macos-vm-runner-<commit>` GitHub CI
   artifact. The bundle carries the guest and host installer scripts.
2. Boot a clean macOS 15 Tart guest with Tart Guest Agent, Git, trusted CA
   roots and command-line developer tools. Transfer the bundle through
   `tart exec -i`. In the guest, run `sudo bash install-guest.sh /path/to/bundle --asg`.
   The `--asg` installer creates the administrator policy, validates it with
   `visudo`, disables remote login and checks the account can use `sudo -n`.
   Shut down the template cleanly and use `tart export` to create its `.tvm`.
3. On a dedicated ARM64 EC2 Mac builder running macOS 26, verify AWS CLI v2
   and SSM Agent are available and verify Tart and Softnet against the pins in
   `deploy/macos/runtime.json`. Install the prepared guest and host runtime by
   running `sudo bash install-asg-host.sh BUNDLE TART_APP SOFTNET GUEST_EXPORT.tvm`
   from the bundle. The installer names the stopped guest `moonhub-macos-15`.
4. Create a private AMI from the clean builder. Keep it free of enrollment
   state, AWS CLI profiles, SSH keys, registry credentials and signing identities.
   Ensure EC2 macOS Init and SSM start on a fresh instance. Verify root volume
   encryption, DeleteOnTermination and the absence of persistent additional
   storage. Keep the AMI and its approved launch template version immutable.

## Create the pool and enroll

AWS supports Mac instances on On-Demand Dedicated Hosts. Create a dedicated
[Host Resource Group](https://docs.aws.amazon.com/license-manager/latest/userguide/host-resource-group-create.html)
with **License configuration not required** and restrict it to the intended
Mac instance family. Use host auto-allocation and auto-release according to the
capacity you want to reserve. Dedicated Host allocation has a 24-hour minimum;
the group can have zero EC2 instances while the underlying hosts are still
allocated. AWS scrubs a physical Mac before it can be assigned to another EC2
instance. On Apple Silicon that can take up to 4.5 hours.

Deploy `deploy/asg-vm-pool.yml` with `GuestPlatform=macos`, `Image`,
`MacInstanceType`, `MacHostResourceGroupArn` and an AZ that offers your
instance type (`MacAvailabilityZone`). The stack creates a zero-capacity ASG
in a separate VPC with no inbound rules and HTTP/HTTPS egress. `MacRootVolumeSize`
defaults to 160 GiB. Match `MacRootDeviceName` to the AMI's `RootDeviceName`.
Use the instance limit and standby count to control pool
capacity. With zero standby, allow for the EC2 Mac cold boot before a job starts.

Create a distinct provider with `self-hosted,macos,arm64,macos-15,macos-vm` and
the intended repository grants. Use a trusted controller outside the EC2 Mac.
Supply the ASG, launch template and bootstrap prefix from the stack outputs.

```sh
moonhub-runner run --mode asg --macos-vm --name macos-vm-asg \
  --server https://moonhub.example \
  --registration-token-file /etc/moonhub-runner/macos-registration \
  --state-dir /var/lib/moonhub-runner/macos-controller \
  --aws /usr/local/bin/aws --region us-west-2 \
  --asg "$MAC_ASG" --launch-template "$MAC_LAUNCH_TEMPLATE" \
  --parameter-prefix "$MAC_BOOTSTRAP_PREFIX" --instance-types mac2.metal \
  --runner-image local:moonhub-macos-15
```

Scope controller mutations to the Mac ASG, the launch template, approved AMIs,
its VPC, and instances tagged `MoonHubMacosVmPool` for that stack. Restrict
`ssm:SendCommand` to its hosts and `AWS-RunShellScript`. Scope `ssm:PutParameter`,
`ssm:AddTagsToResource` and `ssm:DeleteParameter` to the bootstrap prefix. The
instance role from the stack can read only its own tagged bootstrap parameter.
The controller needs the same EC2 metadata, instance profile and EBS permissions
as the other [ASG VM profiles](windows-vm-runner.md#image-and-aws-resources).
The ASG service-linked role and License Manager must have access to the
configured Host Resource Group.

## Verify the rollout

The controller waits for SSM, starts the Mac worker and disables its instance
metadata. It detaches the bootstrap profile, removes the temporary parameter and
checks the EC2 volumes before arming the worker. The host stops SSM Agent and
uses Softnet for the guest, blocking the host bridge address, private networks
and the instance metadata link-local range. The guest receives only the job
assignment and its attempt credential, with no host filesystem mounts. Readiness
requires a clean guest on macOS 15 with the administrator account and working
passwordless sudo.

Verify a standard `macos-15` job can checkout, run `sudo -n id -u` and write a
root-owned marker. Rerun the job and verify a new EC2 instance, a fresh guest and
no marker. Repeat for failure and cancellation. Verify both guest deletion and
EC2 termination, root volume deletion and bootstrap parameter deletion. The
controller terminates the EC2 worker after the job even if guest cleanup does
not report completion. Keep the controller active until those checks pass.
