///|
pub(all) struct ManagedOptions {
  base : Options
  name : String
  mode : String
  state_dir : String
  registration_token_file : String
  aws : String
  region : String
  asg : String
  spot_asg : String
  launch_template : String
  parameter_prefix : String
  instance_types : Array[String]
}

///|
fn config_field(
  name : String,
  title : String,
  kind : String,
  help : String,
  choices~ : Array[String] = [],
  minimum~ : Int32 = 0,
  maximum~ : Int32 = 0,
) -> @protocol.ConfigField {
  { name, title, kind, help, choices, minimum, maximum, required: true, }
}

///|
pub fn config_schema(options : ManagedOptions) -> Array[@protocol.ConfigField] {
  let schema = [
    config_field(
      "runner_image", "Runner image", "text", "Applied to new tasks; existing tasks finish first.",
    ),
    config_field(
      "cpus",
      "CPU limit per task",
      "integer",
      "Each worker executes one task at a time.",
      minimum=1,
      maximum=256,
    ),
    config_field(
      "memory_mib",
      "Memory limit per task (MiB)",
      "integer",
      "Leave memory for the operating system and Docker.",
      minimum=256,
      maximum=1048576,
    ),
  ]
  if options.mode == "asg" {
    schema.push(
      config_field(
        "instance_type",
        "Instance type",
        "choice",
        "Changes replace workers after their tasks finish.",
        choices=options.instance_types,
      ),
    )
    schema.push(
      config_field(
        "max_workers",
        "Maximum workers",
        "integer",
        "Maximum total workers across both groups.",
        minimum=1,
        maximum=20,
      ),
    )
    schema.push(
      config_field(
        "idle_seconds",
        "Idle timeout (seconds)",
        "integer",
        "Drain idle workers before terminating them.",
        minimum=30,
        maximum=3600,
      ),
    )
    schema.push(
      config_field(
        "template_version",
        "Launch template version",
        "integer",
        "Use an immutable, pre-built AMI version. Existing workers drain before replacement.",
        minimum=1,
        maximum=1000000,
      ),
    )
    schema.push(
      config_field(
        "purchase_policy",
        "Purchase policy",
        "choice",
        "Spot waits for capacity before using the separate On-Demand group.",
        choices=if options.spot_asg.is_empty() {
          ["on-demand"]
        } else {
          ["on-demand", "spot-with-on-demand-fallback"]
        },
      ),
    )
    schema.push(
      config_field(
        "spot_wait_seconds",
        "Spot capacity wait (seconds)",
        "integer",
        "Fallback only for capacity not yet allocated; starting instances count as allocated.",
        minimum=30,
        maximum=600,
      ),
    )
    schema.push(
      config_field(
        "standby_workers",
        "Standby workers",
        "integer",
        "Keep this many idle workers in addition to active and queued work. Limited by Maximum workers; 0 allows scale-to-zero.",
        minimum=0,
        maximum=20,
      ),
    )
  }
  schema
}

///|
pub fn config_defaults(options : ManagedOptions) -> Map[String, String] {
  let defaults : Map[String, String] = {
    "runner_image": options.base.runner_image,
    "cpus": "2",
    "memory_mib": "4096",
  }
  if options.mode == "asg" {
    defaults["instance_type"] = options.instance_types[0]
    defaults["max_workers"] = "1"
    defaults["standby_workers"] = "0"
    defaults["idle_seconds"] = "600"
    defaults["template_version"] = "1"
    defaults["purchase_policy"] = "on-demand"
    defaults["spot_wait_seconds"] = "120"
  }
  defaults
}

///|
async fn private_token(path : String) -> String {
  guard @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.file_size(path) <= 256L else {
    raise InvalidConfiguration("Invalid token file.")
  }
  let token = @fs.read_file(path).text().trim().to_owned()
  guard token.length() == 64 &&
    token.iter().all(c => c.is_ascii_digit() || (c >= 'a' && c <= 'f')) else {
    raise InvalidConfiguration("Invalid token.")
  }
  token
}

///|
#derive(ToJson, FromJson)
priv struct RegistrationBinding {
  server : String
  name : String
  mode : String
}

///|
pub async fn run_managed(options : ManagedOptions) -> Unit {
  guard ["docker", "asg"].contains(options.mode) && !options.name.is_empty() else {
    raise InvalidConfiguration("Choose docker or asg and a provider name.")
  }
  validate_origin(options.base.server, options.base.allow_http)
  guard !options.instance_types.is_empty() else {
    raise InvalidConfiguration(
      "At least one allowed instance type is required.",
    )
  }
  @fs.mkdir(
    options.state_dir,
    recursive=true,
    permission=0o700,
    allow_exist=true,
  )
  let token_path = options.state_dir + "/provider-token"
  let token = if @fs.exists(token_path) {
    private_token(token_path)
  } else {
    let token = random_hex(32)
    @fs.write_file(
      token_path,
      token,
      create_mode=@fs.CreateNew,
      permission=0o600,
    )
    token
  }
  let registered_path = options.state_dir + "/registered.json"
  if @fs.exists(registered_path) {
    let binding : RegistrationBinding = @json.from_json(
      @json.parse(@fs.read_file(registered_path).text()),
    )
    guard binding.server == options.base.server &&
      binding.name == options.name &&
      binding.mode == options.mode else {
      raise InvalidConfiguration(
        "State directory belongs to another server, provider or mode.",
      )
    }
  } else {
    let request : @protocol.RegisterProviderRequest = {
      version: 1,
      name: options.name,
      mode: options.mode,
      provider_token: token,
      schema: config_schema(options),
      defaults: config_defaults(options),
    }
    ignore(
      control_request(
        options.base.server,
        "/providers/register",
        private_token(options.registration_token_file),
        ToJson::to_json(request),
        allow_http=options.base.allow_http,
      ),
    )
    let binding : RegistrationBinding = {
      server: options.base.server,
      name: options.name,
      mode: options.mode,
    }
    @fs.write_file(
      registered_path,
      ToJson::to_json(binding).stringify(),
      create_mode=@fs.CreateNew,
      permission=0o600,
    )
  }
  // A fresh process has a fresh lease owner, preventing two controllers from
  // concurrently changing the same ASG even when their state is copied.
  let controller_id = random_hex(16)
  if options.mode == "asg" {
    run_asg(options, token, controller_id)
    return
  }
  let worker_token = random_hex(32)
  let key = "docker-" + controller_id
  let observed = Ref("0")
  let applied = Ref("0")
  let started = Ref(false)
  @async.with_task_group(group => {
    for ;; {
      let request : @protocol.ProviderSyncRequest = {
        version: 1,
        controller_id,
        observed_revision: observed.val,
        applied_revision: applied.val,
        schema: Some(config_schema(options)),
        defaults: Some(config_defaults(options)),
        status: if applied.val == "0" {
          "pending"
        } else {
          "applied"
        },
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
      guard snapshot.mode == options.mode else {
        raise InvalidConfiguration("Registered provider mode differs.")
      }
      guard ToJson::to_json(snapshot.schema).stringify() ==
        ToJson::to_json(config_schema(options)).stringify() else {
        raise InvalidConfiguration(
          "Registered schema differs from the local backend allowlist. Use the original startup configuration.",
        )
      }
      observed.val = snapshot.config_revision
      if !started.val {
        let now = @env.now().reinterpret_as_int64()
        let mut waiting = false
        for old in snapshot.workers {
          if old.key == key {
            continue
          }
          if !old.draining {
            ignore(
              control_request(
                options.base.server,
                "/workers/" + old.id + "/drain",
                token,
                { "version": 1 },
                allow_http=options.base.allow_http,
              ),
            )
          }
          if old.active_attempts > 0 ||
            (
              !["drained", "failed"].contains(old.state) &&
              now - @protocol.parse_decimal(old.last_seen_ms).unwrap_or(now) <
              180000L
            ) {
            waiting = true
          }
        }
        if waiting {
          @async.sleep(5000)
          continue
        }
        let request : @protocol.WorkerRegistration = {
          version: 1,
          key,
          token: worker_token,
        }
        ignore(
          control_request(
            options.base.server,
            "/workers/register",
            token,
            ToJson::to_json(request),
            allow_http=options.base.allow_http,
          ),
        )
        group.spawn_bg(() => run_worker(options.base, worker_token))
        started.val = true
      }
      if snapshot.workers.iter().find_first(w => w.key == key) is Some(worker) {
        if worker.applied_revision == observed.val {
          applied.val = observed.val
        }
      }
      @async.sleep(5000)
    }
  })
}
