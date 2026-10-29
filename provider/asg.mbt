///|
priv struct CloudInstance {
  id : String
  lifecycle : String
  scale_in_protected : Bool
  instance_type : String
  template_version : String
} derive(FromJson)

///|
priv struct CloudGroup {
  name : String
  min : Int32
  max : Int32
  desired : Int32
  instances : Array[CloudInstance]
} derive(FromJson)

///|
priv struct WorkerBootstrap {
  server : String
  token : String
  allow_http : Bool
  runner_image : String
} derive(ToJson, FromJson)

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
async fn provision_worker(
  options : ManagedOptions,
  token : String,
  instance : CloudInstance,
) -> Unit {
  let path = options.state_dir + "/" + instance.id + ".token"
  let worker_token = if @fs.exists(path) {
    private_token(path)
  } else {
    let secret = random_hex(32)
    @fs.write_file(path, secret, create_mode=@fs.CreateNew, permission=0o600)
    secret
  }
  let registration : @protocol.WorkerRegistration = {
    version: 1,
    key: instance.id,
    token: worker_token,
  }
  ignore(
    control_request(
      options.base.server,
      "/workers/register",
      token,
      ToJson::to_json(registration),
      allow_http=options.base.allow_http,
    ),
  )
  let parameter = options.parameter_prefix + "/" + instance.id
  let bootstrap : WorkerBootstrap = {
    server: options.base.server,
    token: worker_token,
    allow_http: options.base.allow_http,
    runner_image: options.base.runner_image,
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
  // Only resource names occur in SSM history. The credential is downloaded by
  // the instance into a root-only tmpfs file and never appears in a shell argv.
  let command = "set -eu; install -d -m 700 /run/moonhub-runner; umask 077; aws ssm get-parameter --region " +
    options.region +
    " --name " +
    parameter +
    " --with-decryption --query Parameter.Value --output text > /run/moonhub-runner/bootstrap.json; systemctl is-active --quiet moonhub-runner-worker || systemd-run --unit=moonhub-runner-worker --collect /usr/local/bin/moonhub-runner worker --bootstrap-file /run/moonhub-runner/bootstrap.json"
  ignore(
    aws_request(
      options,
      ["ssm", "send-command"],
      body=Some({
        "InstanceIds": [instance.id],
        "DocumentName": "AWS-RunShellScript",
        "Parameters": { "commands": [command] },
        "TimeoutSeconds": 60,
      }),
    ),
  )
}

///|
async fn reconcile_group(
  options : ManagedOptions,
  token : String,
  snapshot : @protocol.ProviderSnapshot,
  group : CloudGroup,
  excess : Ref[Int32],
) -> Unit {
  let now = @env.now().reinterpret_as_int64()
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
    match worker {
      None => provision_worker(options, token, instance)
      Some(worker) => {
        let seen = @protocol.parse_decimal(worker.last_seen_ms).unwrap_or(0L)
        let idle = @protocol.parse_decimal(worker.idle_since_ms).unwrap_or(now)
        let obsolete = instance.instance_type !=
          snapshot.config.get("instance_type").unwrap_or("") ||
          instance.template_version !=
          snapshot.config.get("template_version").unwrap_or("")
        let expired = now - seen > 180000L
        if worker.state == "starting" && !expired {
          provision_worker(options, token, instance)
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
          (worker.state == "drained" || worker.state == "failed" || expired) {
          ignore(
            aws_request(options, [
              "autoscaling",
              "terminate-instance-in-auto-scaling-group",
              "--instance-id",
              instance.id,
              "--should-decrement-desired-capacity",
            ]),
          )
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
    }
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
  let observed = Ref("0")
  let applied = Ref("0")
  let status = Ref("pending")
  let spot_wait = Ref(0L)
  let latest : Ref[@protocol.ProviderSnapshot?] = Ref(None)
  @async.with_task_group(tasks => {
    tasks.spawn_bg(() => {
      for ;; {
        let request : @protocol.ProviderSyncRequest = {
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
          validate_cloud_configuration(options, snapshot.config)
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
        reconcile_group(options, token, snapshot, on_demand, excess)
        if spot is Some(spot) {
          reconcile_group(options, token, snapshot, spot, excess)
        }
        // Termination decrements desired capacity. Always refresh before scaling
        // so a stale count cannot recreate the instance just retired.
        let fresh_on = cloud_group(options, options.asg)
        let fresh_spot = if spot is Some(spot) {
          Some(cloud_group(options, spot.name))
        } else {
          None
        }
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
priv struct InstanceCapacity {
  cpus : Int32
  memory_mib : Int32
  architectures : Array[String]
} derive(FromJson)

///|
async fn validate_cloud_configuration(
  options : ManagedOptions,
  config : Map[String, String],
) -> Unit {
  let instance_type = config.get("instance_type").unwrap_or("")
  guard options.instance_types.contains(instance_type) else {
    raise InvalidConfiguration("Instance type outside local allowlist.")
  }
  let result = aws_request(options, [
    "ec2", "describe-instance-types", "--instance-types", instance_type, "--query",
    "InstanceTypes[].{cpus:VCpuInfo.DefaultVCpus,memory_mib:MemoryInfo.SizeInMiB,architectures:ProcessorInfo.SupportedArchitectures}",
  ])
  let capacities : Array[InstanceCapacity] = @json.from_json(result)
  guard capacities.length() == 1 &&
    number(config, "cpus") <= capacities[0].cpus &&
    number(config, "memory_mib") + 512 <= capacities[0].memory_mib else {
    raise InvalidConfiguration(
      "Task limits exceed instance resources; reserve at least 512 MiB for the host.",
    )
  }
  let templates = aws_request(options, [
    "ec2",
    "describe-launch-template-versions",
    "--launch-template-id",
    options.launch_template,
    "--versions",
    config.get("template_version").unwrap_or(""),
    "--query",
    "LaunchTemplateVersions[].{image:LaunchTemplateData.ImageId,tokens:LaunchTemplateData.MetadataOptions.HttpTokens,hop:LaunchTemplateData.MetadataOptions.HttpPutResponseHopLimit}",
  ])
  let templates : Array[WorkerTemplate] = @json.from_json(templates)
  guard templates.length() == 1 &&
    templates[0].tokens == Some("required") &&
    templates[0].hop == Some(1) else {
    raise InvalidConfiguration(
      "Pin an AMI and require IMDSv2 with hop limit one to keep host credentials outside job containers.",
    )
  }
  let images = [templates[0].image]
  let architectures = aws_request(options, [
    "ec2",
    "describe-images",
    "--image-ids",
    images[0],
    "--query",
    "Images[].Architecture",
  ])
  let architectures : Array[String] = @json.from_json(architectures)
  guard architectures.length() == 1 &&
    capacities[0].architectures.contains(architectures[0]) else {
    raise InvalidConfiguration("AMI and instance architectures differ.")
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
  run_worker(
    {
      ..base,
      server: bootstrap.server,
      runner_server: bootstrap.server,
      allow_http: bootstrap.allow_http,
      runner_image: bootstrap.runner_image,
    },
    bootstrap.token,
  )
}

///|
priv struct WorkerTemplate {
  image : String
  tokens : String?
  hop : Int32?
} derive(FromJson)
