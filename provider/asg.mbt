///|
#derive(FromJson)
priv struct CloudInstance {
  id : String
  lifecycle : String
  scale_in_protected : Bool
  instance_type : String
  template_version : String
}

///|
#derive(FromJson)
priv struct CloudGroup {
  name : String
  min : Int32
  max : Int32
  desired : Int32
  instances : Array[CloudInstance]
}

///|
#derive(ToJson, FromJson)
priv struct WorkerBootstrap {
  server : String
  token : String
  allow_http : Bool
  runner_image : String
  runner_os : String?
  linux_ci : Bool?
  windows_vm : Bool?
}

///|
fn valid_cloud_name(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 200 &&
  value
  .iter()
  .all(c => {
    c.is_ascii_alphabetic() ||
    c.is_ascii_digit() ||
    c == '-' ||
    c == '_' ||
    c == '.'
  })
}

///|
async fn aws_request(
  options : ManagedOptions,
  args : Array[String],
  body~ : Json? = None,
) -> Json {
  let args = args.copy()
  args.append([
    "--region",
    options.region,
    "--output",
    "json",
    "--no-cli-pager",
    "--cli-connect-timeout",
    "5",
    "--cli-read-timeout",
    "15",
  ])
  let path = options.state_dir + "/aws-" + random_hex(16) + ".json"
  if body is Some(body) {
    @fs.write_file(
      path,
      body.stringify(),
      create_mode=@fs.CreateNew,
      permission=0o600,
    )
    args.append(["--cli-input-json", "file://" + path])
  }
  defer (@fs.remove(path) catch { _ => () })
  @async.with_timeout(25000, () => {
    let (code, output) = @process.collect_output_merged(options.aws, args)
    // Never echo AWS output: SSM values and user data may contain credentials.
    guard code == 0 else {
      raise InvalidConfiguration(
        "AWS request failed; inspect AWS permissions and resource configuration.",
      )
    }
    let text = output.text().trim()
    if text.is_empty() {
      Json::null()
    } else {
      @json.parse(text)
    }
  })
}

///|
async fn cloud_group(options : ManagedOptions, name : String) -> CloudGroup {
  let result = aws_request(options, [
    "autoscaling", "describe-auto-scaling-groups", "--auto-scaling-group-names",
    name, "--query", "AutoScalingGroups[].{name:AutoScalingGroupName,min:MinSize,max:MaxSize,desired:DesiredCapacity,instances:Instances[].{id:InstanceId,lifecycle:LifecycleState,scale_in_protected:ProtectedFromScaleIn,instance_type:InstanceType,template_version:LaunchTemplate.Version}}",
  ])
  let groups : Array[CloudGroup] = @json.from_json(result)
  guard groups.length() == 1 &&
    groups[0].name == name &&
    groups[0].min == 0 &&
    groups[0].max >= 1 else {
    raise InvalidConfiguration(
      "Use an existing dedicated ASG with minimum zero.",
    )
  }
  groups[0]
}

///|
fn number(
  config : Map[String, String],
  name : String,
) -> Int32 raise ProviderError {
  guard config.get(name) is Some(value) &&
    @protocol.parse_decimal(value) is Some(value) &&
    value <= 1000000L else {
    raise InvalidConfiguration("Invalid numeric backend setting.")
  }
  value.to_int()
}

///|
async fn set_capacity(
  options : ManagedOptions,
  group : CloudGroup,
  desired : Int32,
) -> Unit {
  if desired == group.desired {
    return
  }
  guard desired >= group.instances.length() && desired <= group.max else {
    raise InvalidConfiguration(
      "Capacity change would bypass worker draining or exceed the ASG limit.",
    )
  }
  ignore(
    aws_request(options, [
      "autoscaling",
      "set-desired-capacity",
      "--auto-scaling-group-name",
      group.name,
      "--desired-capacity",
      desired.to_string(),
    ]),
  )
}

///|
async fn configure_group(
  options : ManagedOptions,
  name : String,
  config : Map[String, String],
  spot : Bool,
) -> Unit {
  let instance_type = config.get("instance_type").unwrap_or("")
  guard options.instance_types.contains(instance_type) else {
    raise InvalidConfiguration("Instance type is outside the local allowlist.")
  }
  let version = config.get("template_version").unwrap_or("")
  let group = cloud_group(options, name)
  guard group.max >= number(config, "max_workers") else {
    raise InvalidConfiguration("Requested workers exceed the ASG maximum.")
  }
  // Preserve AMI, networking, instance profile and boot data in the locally
  // pinned template. Only the permitted instance type is overridden remotely.
  let policy : Json = {
    "LaunchTemplate": {
      "LaunchTemplateSpecification": {
        "LaunchTemplateId": options.launch_template,
        "Version": version,
      },
      "Overrides": [{ "InstanceType": instance_type }],
    },
    "InstancesDistribution": {
      "OnDemandBaseCapacity": 0,
      "OnDemandPercentageAboveBaseCapacity": if spot {
        0
      } else {
        100
      },
      "SpotAllocationStrategy": "price-capacity-optimized",
    },
  }
  ignore(
    aws_request(
      options,
      ["autoscaling", "update-auto-scaling-group"],
      body=Some({
        "AutoScalingGroupName": name,
        "NewInstancesProtectedFromScaleIn": true,
        "MixedInstancesPolicy": policy,
      }),
    ),
  )
}

///|
async fn register_instance_worker(
  options : ManagedOptions,
  token : String,
  instance_id : String,
) -> (@protocol.WorkerView, String) {
  let path = options.state_dir + "/" + instance_id + ".token"
  let worker_token = if @fs.exists(path) {
    private_token(path)
  } else {
    let secret = random_hex(32)
    @fs.write_file(path, secret, create_mode=@fs.CreateNew, permission=0o600)
    secret
  }
  let registration : @protocol.WorkerRegistration = {
    version: 1,
    key: instance_id,
    token: worker_token,
  }
  let worker : @protocol.WorkerView = @json.from_json(
    control_request(
      options.base.server,
      "/workers/register",
      token,
      ToJson::to_json(registration),
      allow_http=options.base.allow_http,
    ),
  )
  (worker, worker_token)
}

///|
async fn provision_worker(
  options : ManagedOptions,
  token : String,
  instance : CloudInstance,
  runner_os : String,
  config : Map[String, String],
  revision : String,
  controller_id : String,
) -> Unit {
  let single_use = options.base.execution_mode() is Some(_)
  if single_use {
    // Journal before publishing any instance credential. Spot interruption or
    // ASG health replacement can remove an instance without our terminate path.
    @fs.write_file(
      options.state_dir + "/" + instance.id + ".ci-retire",
      "retire",
      permission=0o600,
    )
  }
  let (worker, worker_token) = register_instance_worker(
    options,
    token,
    instance.id,
  )
  let parameter = options.parameter_prefix + "/" + instance.id
  let receipt = options.state_dir + "/" + instance.id + ".bootstrap-command"
  if !single_use || !@fs.exists(receipt) {
    let bootstrap : WorkerBootstrap = {
      server: options.base.server,
      token: worker_token,
      allow_http: options.base.allow_http,
      runner_image: config
      .get("runner_image")
      .unwrap_or(options.base.runner_image),
      runner_os: Some(runner_os),
      linux_ci: Some(options.base.linux_ci),
      windows_vm: if options.base.windows_vm {
        Some(true)
      } else {
        None
      },
    }
    ignore(
      aws_request(
        options,
        ["ssm", "put-parameter"],
        body=Some({
          "Name": parameter,
          "Type": "SecureString",
          "Value": ToJson::to_json(bootstrap).stringify(),
          "Overwrite": true,
        }),
      ),
    )
    if single_use {
      let identity = aws_request(options, ["sts", "get-caller-identity"])
      guard identity is { "Account": String(account), .. } &&
        account.length() == 12 &&
        account.iter().all(c => c.is_ascii_digit()) else {
        raise InvalidConfiguration(
          "Cannot establish the bootstrap instance ARN.",
        )
      }
      ignore(
        aws_request(options, [
          "ssm",
          "add-tags-to-resource",
          "--resource-type",
          "Parameter",
          "--resource-id",
          parameter,
          "--tags",
          "Key=MoonHubInstanceArn,Value=arn:aws:ec2:\{options.region}:\{account}:instance/\{instance.id}",
        ]),
      )
    }
  }
  // Only resource names occur in SSM history. The credential is downloaded by
  // the instance into a private file and never appears in a shell argv.
  let (document, command) = worker_bootstrap_command(
    options.region,
    parameter,
    runner_os,
    linux_ci=options.base.linux_ci,
    windows_vm=options.base.windows_vm,
  )
  let command_id = if single_use && @fs.exists(receipt) {
    let id = @fs.read_file(receipt).text()
    guard valid_cloud_name(id) else {
      raise InvalidConfiguration("Invalid saved bootstrap command.")
    }
    id
  } else {
    let response = aws_request(
      options,
      ["ssm", "send-command"],
      body=Some({
        "InstanceIds": [instance.id],
        "DocumentName": document,
        "Parameters": { "commands": [command] },
        "TimeoutSeconds": 60,
      }),
    )
    if single_use {
      guard response is { "Command": { "CommandId": String(id), .. }, .. } &&
        valid_cloud_name(id) else {
        raise InvalidConfiguration("Invalid bootstrap command identity.")
      }
      @fs.write_file(receipt, id, create_mode=@fs.CreateNew, permission=0o600)
      id
    } else {
      ""
    }
  }
  if single_use {
    // First let SSM download this instance's bootstrap. The worker
    // service waits; no task can run until the outside controller disables IMDS.
    let response = aws_request(options, [
      "ssm",
      "get-command-invocation",
      "--command-id",
      command_id,
      "--instance-id",
      instance.id,
    ])
    guard response is { "Status": "Success", .. } else { return }
    ignore(
      aws_request(options, [
        "ec2",
        "modify-instance-metadata-options",
        "--instance-id",
        instance.id,
        "--http-endpoint",
        "disabled",
        "--http-tokens",
        "required",
        "--http-put-response-hop-limit",
        "1",
      ]),
    )
    let metadata = aws_request(options, [
      "ec2",
      "describe-instances",
      "--instance-ids",
      instance.id,
      "--query",
      "Reservations[0].Instances[0].MetadataOptions",
    ])
    guard metadata is { "State": "applied", "HttpEndpoint": "disabled", .. } else {
      return
    }
    if options.base.windows_vm {
      guard isolate_windows_vm(options, instance.id, parameter) else { return }
    }
    if !worker.draining && worker.active_attempts == 0 {
      ignore(
        control_request(
          options.base.server,
          "/workers/" + worker.id + "/isolation",
          token,
          { "version": 1, "controller_id": controller_id, "revision": revision },
          allow_http=options.base.allow_http,
        ),
      )
      @fs.write_file(
        options.state_dir + "/" + instance.id + ".armed-" + revision,
        "armed",
        permission=0o600,
      )
    }
  }
}

///|
async fn isolate_windows_vm(
  options : ManagedOptions,
  id : String,
  parameter : String,
) -> Bool {
  let associations = aws_request(options, [
    "ec2",
    "describe-iam-instance-profile-associations",
    "--filters",
    "Name=instance-id,Values=" + id,
    "--query",
    "IamInstanceProfileAssociations[].{id:AssociationId,state:State}",
  ])
  guard associations is Array(associations) else {
    raise InvalidConfiguration(
      "Cannot verify the VM bootstrap role was removed.",
    )
  }
  for association in associations {
    match association {
      { "state": "disassociated", .. } => ()
      { "state": "associated", "id": String(association), .. } if valid_cloud_name(
          association,
        ) => {
        ignore(
          aws_request(options, [
            "ec2", "disassociate-iam-instance-profile", "--association-id", association,
          ]),
        )
        return false
      }
      _ => return false
    }
  }
  delete_ci_parameter(options, parameter)
  let result = aws_request(options, [
    "ec2", "describe-instances", "--instance-ids", id, "--query", "Reservations[].Instances[].BlockDeviceMappings[].Ebs.[VolumeId,DeleteOnTermination]",
  ])
  guard result is Array(mappings) && !mappings.is_empty() else {
    raise InvalidConfiguration("Cannot verify the VM has disposable disks.")
  }
  let volumes = mappings.map(mapping => {
    guard mapping is [String(volume), true] &&
      volume.has_prefix("vol-") &&
      valid_cloud_name(volume) else {
      raise InvalidConfiguration("Cannot verify the VM has disposable disks.")
    }
    volume
  })
  @fs.write_file(
    options.state_dir + "/" + id + ".ci-volumes",
    ToJson::to_json(volumes).stringify(),
    permission=0o600,
  )
  true
}

///|
async fn delete_ci_parameter(
  options : ManagedOptions,
  parameter : String,
) -> Unit {
  let parameters = aws_request(options, [
    "ssm",
    "describe-parameters",
    "--parameter-filters",
    "Key=Name,Option=Equals,Values=" + parameter,
    "--query",
    "Parameters[].Name",
  ])
  if parameters != Json::array([]) {
    guard parameters == Json::array([Json(parameter)]) else {
      raise InvalidConfiguration("Unexpected CI cleanup parameter.")
    }
    ignore(
      aws_request(options, ["ssm", "delete-parameter", "--name", parameter]),
    )
  }
}

///|
// EC2 LaunchTime is RFC3339 UTC. Parse the calendar through the time library,
// and reject non-UTC offsets rather than silently extending startup leases.
fn instance_launch_ms(value : String) -> Int64 raise {
  guard value.length() >= 20 &&
    value[4:5] == "-" &&
    value[7:8] == "-" &&
    value[10:11] == "T" &&
    value[13:14] == ":" &&
    value[16:17] == ":" else {
    raise InvalidConfiguration("Invalid EC2 launch timestamp.")
  }
  let suffix = value[19:]
  let fraction = if suffix.has_suffix("Z") {
    suffix.strip_suffix("Z").unwrap()
  } else if suffix.has_suffix("+00:00") {
    suffix.strip_suffix("+00:00").unwrap()
  } else {
    raise InvalidConfiguration("EC2 launch timestamp must use UTC.")
  }
  guard fraction.is_empty() ||
    (
      fraction.strip_prefix(".") is Some(digits) &&
      !digits.is_empty() &&
      digits.length() <= 9 &&
      digits.iter().all(c => c.is_ascii_digit())
    ) else {
    raise InvalidConfiguration("EC2 launch timestamp must use UTC.")
  }
  @time.date_time(
    @string.parse_int(value[:4].to_owned()),
    @string.parse_int(value[5:7].to_owned()),
    @string.parse_int(value[8:10].to_owned()),
    hour=@string.parse_int(value[11:13].to_owned()),
    minute=@string.parse_int(value[14:16].to_owned()),
    second=@string.parse_int(value[17:19].to_owned()),
    zone=@time.utc_zone,
  ).to_unix_second() *
  1000L
}

///|
priv enum InstanceStartup {
  Online
  Booting
  TimedOut
}

///|
async fn instance_startup(
  options : ManagedOptions,
  instance_id : String,
  now : Int64,
) -> InstanceStartup {
  let online : Array[String] = @json.from_json(
    aws_request(options, [
      "ssm",
      "describe-instance-information",
      "--filters",
      "Key=InstanceIds,Values=" + instance_id,
      "Key=PingStatus,Values=Online",
      "--query",
      "InstanceInformationList[].InstanceId",
    ]),
  )
  if online.contains(instance_id) {
    return Online
  }
  let launches : Array[String] = @json.from_json(
    aws_request(options, [
      "ec2", "describe-instances", "--instance-ids", instance_id, "--query", "Reservations[].Instances[].LaunchTime",
    ]),
  )
  guard launches.length() == 1 else {
    raise InvalidConfiguration("Cannot establish the EC2 startup deadline.")
  }
  let launch = instance_launch_ms(launches[0])
  guard launch <= now + 30000L else {
    raise InvalidConfiguration("EC2 launch timestamp is in the future.")
  }
  if now - launch < 900000L {
    Booting
  } else {
    TimedOut
  }
}

///|
async fn reconcile_group(
  options : ManagedOptions,
  token : String,
  snapshot : @protocol.ProviderSnapshot,
  group : CloudGroup,
  excess : Ref[Int32],
  runner_os : String,
  controller_id : String,
) -> Unit {
  let now = @env.now().reinterpret_as_int64()
  let single_use = options.base.execution_mode() is Some(_)
  let idle_seconds = number(snapshot.config, "idle_seconds").to_int64()
  let timeout_ms = idle_seconds * 1000L
  for instance in group.instances {
    guard valid_cloud_name(instance.id) else {
      raise InvalidConfiguration("Invalid AWS instance identity.")
    }
    if instance.lifecycle != "InService" {
      continue
    }
    if !instance.scale_in_protected {
      ignore(
        aws_request(options, [
          "autoscaling",
          "set-instance-protection",
          "--auto-scaling-group-name",
          group.name,
          "--instance-ids",
          instance.id,
          "--protected-from-scale-in",
        ]),
      )
    }
    let worker = snapshot.workers.iter().find_first(w => w.key == instance.id)
    if worker is Some(worker) {
      let seen = @protocol.parse_decimal(worker.last_seen_ms).unwrap_or(0L)
      let idle = @protocol.parse_decimal(worker.idle_since_ms).unwrap_or(now)
      let obsolete = instance.instance_type !=
        snapshot.config.get("instance_type").unwrap_or("") ||
        instance.template_version !=
        snapshot.config.get("template_version").unwrap_or("")
      let expired = now - seen > 180000L
      if single_use &&
        !worker.draining &&
        !expired &&
        !obsolete &&
        !snapshot.paused &&
        !["drained", "failed"].contains(worker.state) &&
        !@fs.exists(
          options.state_dir +
          "/" +
          instance.id +
          ".armed-" +
          snapshot.config_revision,
        ) {
        provision_worker(
          options,
          token,
          instance,
          runner_os,
          snapshot.config,
          snapshot.config_revision,
          controller_id,
        )
        continue
      }
      if !single_use &&
        worker.state == "starting" &&
        !expired &&
        !obsolete &&
        !worker.draining &&
        !snapshot.paused {
        provision_worker(
          options,
          token,
          instance,
          runner_os,
          snapshot.config,
          snapshot.config_revision,
          controller_id,
        )
        continue
      }
      let retire = obsolete ||
        snapshot.paused ||
        (
          group.name == options.spot_asg &&
          snapshot.config.get("purchase_policy") !=
          Some("spot-with-on-demand-fallback")
        ) ||
        (
          excess.val > 0 &&
          worker.active_attempts == 0 &&
          worker.state == "ready" &&
          now - idle >= timeout_ms
        ) ||
        worker.state == "failed" ||
        expired
      if retire && !worker.draining {
        excess.val -= 1
        ignore(
          control_request(
            options.base.server,
            "/workers/" + worker.id + "/drain",
            token,
            { "version": 1 },
            allow_http=options.base.allow_http,
          ),
        )
        continue
      }
      // Healthy workers must acknowledge cleanup. A lost worker is retired
      // only after its task lease has been reconciled to a terminal state.
      if worker.draining &&
        worker.active_attempts == 0 &&
        (
          single_use ||
          worker.state == "drained" ||
          worker.state == "failed" ||
          expired
        ) {
        if single_use {
          // Persist before requesting termination. A controller interruption
          // or ambiguous AWS response must not lose parameter cleanup.
          @fs.write_file(
            options.state_dir + "/" + instance.id + ".ci-retire",
            "retire",
            permission=0o600,
          )
        }
        ignore(
          aws_request(options, [
            "autoscaling",
            "terminate-instance-in-auto-scaling-group",
            "--instance-id",
            instance.id,
            "--should-decrement-desired-capacity",
          ]),
        )
        @fs.remove(options.state_dir + "/" + instance.id + ".token") catch {
          _ => ()
        }
        @fs.remove(options.state_dir + "/" + instance.id + ".bootstrap-command") catch {
          _ => ()
        }
        @fs.remove(
          options.state_dir +
          "/" +
          instance.id +
          ".armed-" +
          snapshot.config_revision,
        ) catch {
          _ => ()
        }
        if !options.base.windows_vm {
          ignore(
            aws_request(options, [
              "ssm",
              "delete-parameter",
              "--name",
              options.parameter_prefix + "/" + instance.id,
            ]),
          )
        }
      }
    } else if instance.template_version !=
      snapshot.config.get("template_version").unwrap_or("") ||
      instance.instance_type !=
      snapshot.config.get("instance_type").unwrap_or("") {
      // A snapshot may lag a newly registered/busy worker. Recover its
      // identity and drain it before ordinary cleanup/lease-based retirement.
      let (worker, _) = register_instance_worker(options, token, instance.id)
      ignore(
        control_request(
          options.base.server,
          "/workers/" + worker.id + "/drain",
          token,
          { "version": 1 },
          allow_http=options.base.allow_http,
        ),
      )
    } else {
      let startup = instance_startup(options, instance.id, now)
      if startup is Booting && !snapshot.paused {
        // Windows Sysprep can take more than the worker heartbeat lease.
        // EC2 capacity is counted, but no worker or bootstrap credential
        // exists until its management channel can deliver the runtime.
        continue
      }
      if startup is Online && !snapshot.paused {
        provision_worker(
          options,
          token,
          instance,
          runner_os,
          snapshot.config,
          snapshot.config_revision,
          controller_id,
        )
      } else {
        // No work was issued to an unreachable/paused instance. Recover
        // its identity and use ordinary active-attempt/drain safeguards.
        let (worker, _) = register_instance_worker(options, token, instance.id)
        ignore(
          control_request(
            options.base.server,
            "/workers/" + worker.id + "/drain",
            token,
            { "version": 1 },
            allow_http=options.base.allow_http,
          ),
        )
      }
    }
  }
}

///|
async fn cleanup_retired_ci(
  options : ManagedOptions,
  live : Array[String],
) -> Unit {
  if options.base.execution_mode() is None {
    return
  }
  for name in @fs.readdir(options.state_dir) {
    guard name.strip_suffix(".ci-retire") is Some(raw) else { continue }
    let id = raw.to_owned()
    guard id.has_prefix("i-") && valid_cloud_name(id) else {
      raise InvalidConfiguration("Invalid CI retirement journal.")
    }
    if live.contains(id) {
      continue
    }
    let state = aws_request(options, [
      "ec2",
      "describe-instances",
      "--filters",
      "Name=instance-id,Values=" + id,
      "--query",
      "Reservations[].Instances[].State.Name",
    ])
    guard state is ["terminated"] || state == Json::array([]) else { continue }
    let parameter = options.parameter_prefix + "/" + id
    delete_ci_parameter(options, parameter)
    let receipt = options.state_dir + "/" + id + ".ci-volumes"
    if options.base.windows_vm && @fs.exists(receipt) {
      let volumes : Array[String] = @json.from_json(
        @json.parse(@fs.read_file(receipt).text()),
      )
      let present = aws_request(options, [
        "ec2",
        "describe-volumes",
        "--filters",
        "Name=volume-id,Values=" + volumes.join(","),
        "--query",
        "Volumes[].VolumeId",
      ])
      guard present == Json::array([]) else { continue }
      @fs.remove(receipt)
    }
    for file in @fs.readdir(options.state_dir) {
      if file == id + ".token" ||
        file == id + ".bootstrap-command" ||
        file.has_prefix(id + ".armed-") {
        @fs.remove(options.state_dir + "/" + file)
      }
    }
    @fs.remove(options.state_dir + "/" + name)
  }
}

///|
async fn run_asg(
  options : ManagedOptions,
  token : String,
  controller_id : String,
) -> Unit {
  guard valid_cloud_name(options.region) &&
    valid_cloud_name(options.asg) &&
    valid_cloud_name(options.launch_template) &&
    (
      options.spot_asg.is_empty() ||
      (valid_cloud_name(options.spot_asg) && options.spot_asg != options.asg)
    ) &&
    options.parameter_prefix.has_prefix("/moonhub-runner/") &&
    options.parameter_prefix.length() < 160 &&
    options.parameter_prefix
    .iter()
    .all(c => {
      c.is_ascii_alphabetic() ||
      c.is_ascii_digit() ||
      c == '/' ||
      c == '-' ||
      c == '_'
    }) else {
    raise InvalidConfiguration("Invalid ASG bootstrap settings.")
  }
  let runner_os = Ref("linux")
  let observed = Ref("0")
  let applied = Ref("0")
  let status = Ref("pending")
  let spot_wait = Ref(0L)
  let latest : Ref[@protocol.ProviderSnapshot?] = Ref(None)
  @async.with_task_group(tasks => {
    tasks.spawn_bg(() => {
      for ;; {
        let request : @protocol.ProviderSyncRequest = {
          environment_protocol: Some(1),
          version: 1,
          controller_id,
          observed_revision: observed.val,
          applied_revision: applied.val,
          schema: Some(config_schema(options)),
          defaults: Some(config_defaults(options)),
          status: status.val,
        }
        let snapshot : @protocol.ProviderSnapshot = @json.from_json(
          control_request(
            options.base.server,
            "/providers/sync",
            token,
            ToJson::to_json(request),
            allow_http=options.base.allow_http,
          ),
        )
        guard snapshot.mode == "asg" &&
          ToJson::to_json(snapshot.schema).stringify() ==
          ToJson::to_json(config_schema(options)).stringify() else {
          raise InvalidConfiguration("Registered mode differs.")
        }
        latest.val = Some(snapshot)
        @async.sleep(5000)
      }
    })
    for ;; {
      guard latest.val is Some(snapshot) else {
        @async.sleep(100)
        continue
      }
      observed.val = snapshot.config_revision
      try {
        if @protocol.validate_config(config_schema(options), snapshot.config)
          is Some(message) {
          raise InvalidConfiguration(message)
        }
        if applied.val != observed.val {
          runner_os.val = validate_cloud_configuration(options, snapshot.config)
          configure_group(options, options.asg, snapshot.config, false)
          if !options.spot_asg.is_empty() {
            configure_group(options, options.spot_asg, snapshot.config, true)
          }
        }
        let on_demand = cloud_group(options, options.asg)
        let spot = if options.spot_asg.is_empty() {
          None
        } else {
          Some(cloud_group(options, options.spot_asg))
        }
        let desired = desired_workers(snapshot)
        let actual = on_demand.instances.length() +
          spot.map(g => g.instances.length()).unwrap_or(0)
        let live_keys = on_demand.instances.map(i => i.id)
        if spot is Some(spot) {
          live_keys.append(spot.instances.map(i => i.id))
        }
        let excess = Ref(
          actual -
          desired -
          snapshot.workers
          .filter(w => w.draining && live_keys.contains(w.key))
          .length(),
        )
        reconcile_group(
          options,
          token,
          snapshot,
          on_demand,
          excess,
          runner_os.val,
          controller_id,
        )
        if spot is Some(spot) {
          reconcile_group(
            options,
            token,
            snapshot,
            spot,
            excess,
            runner_os.val,
            controller_id,
          )
        }
        // Termination decrements desired capacity. Always refresh before scaling
        // so a stale count cannot recreate the instance just retired.
        let fresh_on = cloud_group(options, options.asg)
        let fresh_spot = if spot is Some(spot) {
          Some(cloud_group(options, spot.name))
        } else {
          None
        }
        let remaining = fresh_on.instances.map(instance => instance.id)
        if fresh_spot is Some(group) {
          remaining.append(group.instances.map(instance => instance.id))
        }
        cleanup_retired_ci(options, remaining)
        let count = fresh_on.instances.length() +
          fresh_spot.map(g => g.instances.length()).unwrap_or(0)
        let now = @env.now().reinterpret_as_int64()
        let prefer_spot = snapshot.config.get("purchase_policy") ==
          Some("spot-with-on-demand-fallback") &&
          fresh_spot is Some(_)
        if count < desired {
          if prefer_spot && fresh_spot is Some(spot) {
            if spot_wait.val == 0L {
              spot_wait.val = now
            }
            if now - spot_wait.val >=
              number(snapshot.config, "spot_wait_seconds").to_int64() * 1000L {
              cancel_pending_capacity(options, spot)
              let checked_spot = cloud_group(options, spot.name)
              let checked_on = cloud_group(options, fresh_on.name)
              let missing = if desired >
                checked_spot.instances.length() + checked_on.instances.length() {
                desired -
                checked_spot.instances.length() -
                checked_on.instances.length()
              } else {
                0
              }
              set_capacity(
                options,
                checked_on,
                checked_on.instances.length() + missing,
              )
            } else {
              cancel_pending_capacity(options, fresh_on)
              set_capacity(
                options,
                spot,
                spot.instances.length() + desired - count,
              )
            }
          } else {
            if fresh_spot is Some(spot) {
              cancel_pending_capacity(options, spot)
            }
            set_capacity(
              options,
              fresh_on,
              fresh_on.instances.length() + desired - count,
            )
          }
        } else {
          spot_wait.val = 0L
          cancel_pending_capacity(options, fresh_on)
          if fresh_spot is Some(spot) {
            cancel_pending_capacity(options, spot)
          }
        }
        applied.val = observed.val
        status.val = if snapshot.workers.any(w => {
            w.draining && live_keys.contains(w.key)
          }) {
          "replacing"
        } else {
          "applied"
        }
      } catch {
        _ => {
          status.val = "failed"
          println(
            "runner: ASG reconciliation failed; check resource permissions, launch template and task limits",
          )
        }
      }
      @async.sleep(5000)
    }
  })
}

///|
fn desired_workers(
  snapshot : @protocol.ProviderSnapshot,
) -> Int32 raise ProviderError {
  if snapshot.paused {
    return 0
  }
  let requested = snapshot.workers.filter(w => w.active_attempts > 0).length() +
    snapshot.queued_jobs +
    number(snapshot.config, "standby_workers")
  let maximum = number(snapshot.config, "max_workers")
  if requested > maximum {
    maximum
  } else {
    requested
  }
}

///|
async fn cancel_pending_capacity(
  options : ManagedOptions,
  group : CloudGroup,
) -> Unit {
  if group.desired > group.instances.length() {
    set_capacity(options, group, group.instances.length())
  }
}

///|
#derive(FromJson)
priv struct InstanceCapacity {
  cpus : Int32
  memory_mib : Int32
  architectures : Array[String]
}

///|
async fn validate_cloud_configuration(
  options : ManagedOptions,
  config : Map[String, String],
) -> String {
  let instance_type = config.get("instance_type").unwrap_or("")
  guard options.instance_types.contains(instance_type) else {
    raise InvalidConfiguration("Instance type outside local allowlist.")
  }
  let result = aws_request(options, [
    "ec2", "describe-instance-types", "--instance-types", instance_type, "--query",
    "InstanceTypes[].{cpus:VCpuInfo.DefaultVCpus,memory_mib:MemoryInfo.SizeInMiB,architectures:ProcessorInfo.SupportedArchitectures}",
  ])
  let capacities : Array[InstanceCapacity] = @json.from_json(result)
  guard capacities.length() == 1 else {
    raise InvalidConfiguration("Could not verify the selected instance type.")
  }
  if options.base.windows_vm {
    guard capacities[0].cpus >= 2 && capacities[0].memory_mib >= 8192 else {
      raise InvalidConfiguration(
        "Windows VM requires at least two vCPUs and 8 GiB of RAM.",
      )
    }
  } else if number(config, "cpus") > capacities[0].cpus ||
    number(config, "memory_mib") + 512 > capacities[0].memory_mib {
    raise InvalidConfiguration(
      "Task limits exceed instance resources; reserve at least 512 MiB for the host.",
    )
  }
  let disks = if options.base.windows_vm {
    ",disks:LaunchTemplateData.BlockDeviceMappings[].Ebs"
  } else {
    ""
  }
  let templates = aws_request(options, [
    "ec2",
    "describe-launch-template-versions",
    "--launch-template-id",
    options.launch_template,
    "--versions",
    config.get("template_version").unwrap_or(""),
    "--query",
    "LaunchTemplateVersions[].{image:LaunchTemplateData.ImageId,tokens:LaunchTemplateData.MetadataOptions.HttpTokens,hop:LaunchTemplateData.MetadataOptions.HttpPutResponseHopLimit" +
    disks +
    "}",
  ])
  let templates : Array[WorkerTemplate] = @json.from_json(templates)
  guard templates.length() == 1 &&
    templates[0].tokens == Some("required") &&
    templates[0].hop == Some(1) else {
    raise InvalidConfiguration(
      "Pin an AMI and require IMDSv2 with hop limit one to keep host credentials outside job containers.",
    )
  }
  guard !options.base.windows_vm ||
    (
      templates[0].disks is Some(disks) &&
      !disks.is_empty() &&
      disks.all(disk => {
        disk is { "DeleteOnTermination": true, "Encrypted": true, .. }
      })
    ) else {
    raise InvalidConfiguration(
      "Windows VM launch templates require explicit encrypted, disposable EBS mappings.",
    )
  }
  let images = [templates[0].image]
  let images = aws_request(options, [
    "ec2",
    "describe-images",
    "--image-ids",
    images[0],
    "--query",
    "Images[].{architecture:Architecture,platform:Platform}",
  ])
  let images : Array[WorkerImage] = @json.from_json(images)
  guard images.length() == 1 &&
    capacities[0].architectures.contains(images[0].architecture) else {
    raise InvalidConfiguration("AMI and instance architectures differ.")
  }
  guard ["x86_64", "arm64"].contains(images[0].architecture) else {
    raise InvalidConfiguration("Unsupported worker AMI architecture.")
  }
  if images[0].platform == Some("windows") {
    guard !options.base.linux_ci else {
      raise InvalidConfiguration(
        "Linux CI cannot use a Windows launch template.",
      )
    }
    guard images[0].architecture == "x86_64" else {
      raise InvalidConfiguration("Windows workers require an x86_64 AMI.")
    }
    "windows"
  } else {
    guard !options.base.windows_vm else {
      raise InvalidConfiguration(
        "Windows VM requires a Windows launch template.",
      )
    }
    "linux"
  }
}

///|
pub async fn run_bootstrap_worker(path : String, base : Options) -> Unit {
  guard @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.file_size(path) <= 8192L else {
    raise InvalidConfiguration("Invalid worker bootstrap.")
  }
  let bootstrap : WorkerBootstrap = @json.from_json(
    @json.parse(@fs.read_file(path).text()),
  )
  guard bootstrap.runner_os.unwrap_or("linux") == @platform.os() else {
    raise InvalidConfiguration("Worker OS does not match its launch template.")
  }
  if bootstrap.linux_ci == Some(true) || bootstrap.windows_vm == Some(true) {
    guard !@fs.exists(base.workspace_root + "/ci-consumed") else {
      raise InvalidConfiguration("This CI instance has already executed a job.")
    }
    @fs.remove(path)
  }
  run_worker(
    {
      ..base,
      server: bootstrap.server,
      runner_server: bootstrap.server,
      allow_http: bootstrap.allow_http,
      runner_image: bootstrap.runner_image,
      linux_ci: bootstrap.linux_ci.unwrap_or(false),
      windows_vm: bootstrap.windows_vm.unwrap_or(false),
    },
    bootstrap.token,
  )
}

///|
#derive(FromJson)
priv struct WorkerTemplate {
  image : String
  tokens : String?
  hop : Int32?
  disks : Array[Json]?
}

///|
priv struct WorkerImage {
  architecture : String
  platform : String?
}

///|
// Resource identifiers are validated before interpolation; credentials stay in
// SecureString and are never placed in SSM command history or process arguments.
fn worker_bootstrap_command(
  region : String,
  parameter : String,
  runner_os : String,
  linux_ci~ : Bool = false,
  windows_vm~ : Bool = false,
) -> (String, String) {
  if windows_vm {
    (
      "AWS-RunPowerShellScript",
      "$ErrorActionPreference='Stop'; & 'C:/moonhub/ci-host.ps1' -BootstrapParameter '\{parameter}' -Region '\{region}'",
    )
  } else if runner_os == "windows" {
    (
      "AWS-RunPowerShellScript",
      "$ErrorActionPreference='Stop'; $dir='C:\\ProgramData\\MoonHub\\private'; " +
      "New-Item -ItemType Directory -Force -Path $dir | Out-Null; " +
      "& icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null; if($LASTEXITCODE -ne 0){throw 'Cannot protect bootstrap directory'}; " +
      "$json = & aws.exe ssm get-parameter --region " +
      region +
      " --name " +
      parameter +
      " --with-decryption --query Parameter.Value --output text; if($LASTEXITCODE -ne 0){throw 'Cannot fetch bootstrap'}; " +
      "[IO.File]::WriteAllText($dir+'\\bootstrap.json',($json -join [Environment]::NewLine),(New-Object Text.UTF8Encoding($false))); " +
      "$task=Get-ScheduledTask -TaskName 'MoonHubRunnerWorker' -ErrorAction SilentlyContinue; if(!$task -or $task.State -ne 'Running'){ " +
      "$action=New-ScheduledTaskAction -Execute 'C:\\ProgramData\\MoonHub\\bin\\moonhub-runner.exe' -Argument 'worker --bootstrap-file C:\\ProgramData\\MoonHub\\private\\bootstrap.json'; " +
      "$settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable; " +
      "Register-ScheduledTask -TaskName 'MoonHubRunnerWorker' -Action $action -Trigger (New-ScheduledTaskTrigger -AtStartup) -User 'SYSTEM' -RunLevel Highest -Settings $settings -Force | Out-Null; Start-ScheduledTask -TaskName 'MoonHubRunnerWorker' }",
    )
  } else if linux_ci {
    (
      "AWS-RunShellScript",
      "set -eu; test -x /usr/local/libexec/moonhub-ci-host; " +
      "install -d -m 700 /run/moonhub-runner; umask 077; aws ssm get-parameter --region " +
      region +
      " --name " +
      parameter +
      " --with-decryption --query Parameter.Value --output text > /run/moonhub-runner/bootstrap.json; " +
      "systemctl is-active --quiet moonhub-runner-worker || systemd-run --unit=moonhub-runner-worker --collect " +
      "/usr/local/libexec/moonhub-ci-host /run/moonhub-runner/bootstrap.json",
    )
  } else {
    (
      "AWS-RunShellScript",
      "set -eu; install -d -m 700 /run/moonhub-runner; umask 077; aws ssm get-parameter --region " +
      region +
      " --name " +
      parameter +
      " --with-decryption --query Parameter.Value --output text > /run/moonhub-runner/bootstrap.json; systemctl is-active --quiet moonhub-runner-worker || systemd-run --unit=moonhub-runner-worker --collect /usr/local/bin/moonhub-runner worker --bootstrap-file /run/moonhub-runner/bootstrap.json",
    )
  }
}

///|
impl @json.FromJson for WorkerImage with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "AMI must be an object"))
  }
  {
    architecture: @json.from_json(
      fields.get("architecture").unwrap_or(Json::null()),
      path=path.add_key("architecture"),
    ),
    platform: match fields.get("platform") {
      None | Some(Null) => None
      Some(value) => Some(@json.from_json(value, path=path.add_key("platform")))
    },
  }
}
