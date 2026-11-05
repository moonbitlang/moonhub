// Adapted from mizchi/actrun src/parser.mbt and src/lowering.mbt, Apache-2.0.
// Modified to use the independent YAML parser and reject unsupported semantics.

///|
fn yaml_as_obj(
  value : @yaml.Yaml,
  ctx : String,
) -> Map[String, @yaml.Yaml] raise InvalidWorkflow {
  match value {
    Map(fields) => fields
    _ => raise InvalidWorkflow("\{ctx} must be a mapping")
  }
}

///|
fn check_fields(
  fields : Map[String, @yaml.Yaml],
  allowed : Array[String],
  ctx : String,
) -> Unit raise InvalidWorkflow {
  for key, _ in fields {
    guard allowed.contains(key) else {
      raise InvalidWorkflow("\{ctx}.\{key} is not supported")
    }
  }
}

///|
fn yaml_as_optional_string(
  value : @yaml.Yaml?,
  ctx : String,
) -> String? raise InvalidWorkflow {
  match value {
    None => None
    Some(String(text)) => {
      guard !text.contains("${{") else {
        raise InvalidWorkflow("\{ctx}: expressions are not supported")
      }
      Some(text)
    }
    _ => raise InvalidWorkflow("\{ctx} must be a string")
  }
}

///|
fn required_string(
  value : @yaml.Yaml?,
  ctx : String,
) -> String raise InvalidWorkflow {
  let text = yaml_as_optional_string(value, ctx).unwrap_or("")
  guard !text.trim().is_empty() else {
    raise InvalidWorkflow("\{ctx} must be a nonempty string")
  }
  text
}

///|
fn yaml_as_string_list(
  value : @yaml.Yaml?,
  ctx : String,
) -> Array[String] raise InvalidWorkflow {
  match value {
    None => []
    Some(String(_)) => [required_string(value, ctx)]
    Some(Array(items)) => {
      let result : Array[String] = []
      for item in items {
        let text = required_string(Some(item), ctx)
        guard !result.contains(text) else {
          raise InvalidWorkflow("\{ctx} contains a duplicate value")
        }
        result.push(text)
      }
      result
    }
    _ => raise InvalidWorkflow("\{ctx} must be a string or list of strings")
  }
}

///|
fn valid_identifier(value : String) -> Bool {
  !value.is_empty() &&
  value.length() <= 100 &&
  value
  .iter()
  .all(ch => {
    ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '_' || ch == '-'
  }) &&
  value.get_char(0) is Some(ch) &&
  (ch.is_ascii_alphabetic() || ch == '_')
}

///|
fn yaml_to_string_map(
  value : @yaml.Yaml?,
  ctx : String,
) -> Map[String, String] raise InvalidWorkflow {
  let result : Map[String, String] = Map([])
  guard value is Some(value) else { return result }
  let fields = yaml_as_obj(value, ctx)
  guard fields.length() <= 100 else {
    raise InvalidWorkflow("\{ctx} exceeds 100 variables")
  }
  for key, value in fields {
    guard valid_identifier(key) &&
      !key.contains("-") &&
      !key.to_upper().has_prefix("MOONHUB_") &&
      !key.to_upper().has_prefix("GITHUB_") &&
      !key.to_upper().has_prefix("RUNNER_") &&
      !key.to_upper().has_prefix("LD_") &&
      !key.to_upper().has_prefix("DYLD_") &&
      !["BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS", "NODE_OPTIONS"].contains(
        key.to_upper(),
      ) else {
      raise InvalidWorkflow("\{ctx}.\{key}: invalid or reserved variable name")
    }
    result[key] = match value {
      String(text) => {
        if secret_reference(text) is None {
          validate_template(text, "\{ctx}.\{key}")
        }
        text
      }
      Integer(n) => n.to_string()
      Boolean(b) => if b { "true" } else { "false" }
      Real(_, repr~) => repr
      _ => raise InvalidWorkflow("\{ctx}.\{key} must be a scalar value")
    }
  }
  result
}

///|
fn merge_env(
  base : Map[String, String],
  overlay : Map[String, String],
  windows~ : Bool = false,
) -> Map[String, String] raise InvalidWorkflow {
  let result : Map[String, String] = Map([])
  for layer in [base, overlay] {
    let seen : Map[String, Bool] = Map([])
    for key, value in layer {
      let key = if windows { key.to_upper() } else { key }
      guard !seen.contains(key) else {
        raise InvalidWorkflow(
          "Windows environment names must be unique ignoring case",
        )
      }
      seen[key] = true
      result[key] = value
    }
  }
  result
}

///|
fn inherit_defaults(base : RunDefaults, overlay : RunDefaults) -> RunDefaults {
  {
    shell: match overlay.shell {
      Some(_) => overlay.shell
      None => base.shell
    },
    working_directory: match overlay.working_directory {
      Some(_) => overlay.working_directory
      None => base.working_directory
    },
  }
}

///|
fn parse_timeout(
  value : @yaml.Yaml?,
  ctx : String,
) -> Int32? raise InvalidWorkflow {
  match value {
    None => None
    Some(Integer(n)) if n >= 1L && n <= 360L => Some(n.to_int())
    _ => raise InvalidWorkflow("\{ctx} must be an integer between 1 and 360")
  }
}

///|
fn parse_shell(
  value : @yaml.Yaml?,
  ctx : String,
) -> String? raise InvalidWorkflow {
  let shell = yaml_as_optional_string(value, ctx)
  guard shell is None ||
    shell == Some("bash") ||
    shell == Some("sh") ||
    shell == Some("pwsh") else {
    raise InvalidWorkflow("\{ctx} supports only bash, sh and pwsh")
  }
  shell
}

///|
fn parse_directory(
  value : @yaml.Yaml?,
  ctx : String,
) -> String? raise InvalidWorkflow {
  let directory = yaml_as_optional_string(value, ctx)
  if directory is Some(path) {
    guard !path.is_empty() &&
      path.length() <= 512 &&
      !path.has_prefix("/") &&
      !path.contains("\\") &&
      !path.contains(":") &&
      path.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127) &&
      path.split("/").all(part => !part.is_empty() && part != "..") else {
      raise InvalidWorkflow(
        "\{ctx} must be a relative workspace path without '..'",
      )
    }
  }
  directory
}

///|
fn parse_run_defaults(
  value : @yaml.Yaml?,
  ctx : String,
) -> RunDefaults raise InvalidWorkflow {
  guard value is Some(value) else {
    return { shell: None, working_directory: None, }
  }
  let defaults = yaml_as_obj(value, ctx)
  check_fields(defaults, ["run"], ctx)
  guard defaults.get("run") is Some(value) else {
    return { shell: None, working_directory: None, }
  }
  let fields = yaml_as_obj(value, "\{ctx}.run")
  check_fields(fields, ["shell", "working-directory"], "\{ctx}.run")
  {
    shell: parse_shell(fields.get("shell"), "\{ctx}.run.shell"),
    working_directory: parse_directory(
      fields.get("working-directory"),
      "\{ctx}.run.working-directory",
    ),
  }
}

///|
fn parse_job(
  id : String,
  value : @yaml.Yaml,
  workflow_env : Map[String, String],
  defaults : RunDefaults,
  contents_read : Bool,
) -> Job raise InvalidWorkflow {
  guard valid_identifier(id) else {
    raise InvalidWorkflow("invalid job id: \{id}")
  }
  let ctx = "jobs.\{id}"
  let fields = yaml_as_obj(value, ctx)
  check_fields(
    fields,
    [
      "name", "runs-on", "needs", "env", "defaults", "timeout-minutes", "steps",
      "permissions",
    ],
    ctx,
  )
  let runs_on = runner_labels(fields.get("runs-on"), "\{ctx}.runs-on")
  guard runs_on.contains("self-hosted") &&
    runs_on.length() <= 8 &&
    runs_on.all(label => {
      !label.is_empty() &&
      label.length() <= 64 &&
      label
      .iter()
      .all(ch => {
        ch.is_ascii_alphabetic() ||
        ch.is_ascii_digit() ||
        ch == '-' ||
        ch == '_' ||
        ch == '.'
      })
    }) &&
    ["linux", "windows", "macos"].filter(os => runs_on.contains(os)).length() <=
    1 else {
    raise InvalidWorkflow(
      "\{ctx}.runs-on requires self-hosted Linux, Windows or macOS runner labels",
    )
  }
  let unique_labels : Map[String, Bool] = Map([])
  for label in runs_on {
    guard !unique_labels.contains(label) else {
      raise InvalidWorkflow("\{ctx}.runs-on contains a duplicate label")
    }
    unique_labels[label] = true
  }
  let env = merge_env(
    workflow_env,
    yaml_to_string_map(fields.get("env"), "\{ctx}.env"),
    windows=runs_on.contains("windows"),
  )
  let job_defaults = inherit_defaults(
    defaults,
    parse_run_defaults(fields.get("defaults"), "\{ctx}.defaults"),
  )
  guard fields.get("steps") is Some(Array(items)) &&
    !items.is_empty() &&
    items.length() <= 64 else {
    raise InvalidWorkflow("\{ctx}.steps requires between 1 and 64 steps")
  }
  let steps : Array[Step] = []
  let step_ids : Map[String, Bool] = Map([])
  for index, value in items {
    let ctx = "\{ctx}.steps[\{index}]"
    let fields = yaml_as_obj(value, ctx)
    check_fields(
      fields,
      [
        "id", "name", "run", "uses", "with", "env", "shell", "working-directory",
        "timeout-minutes", "if", "continue-on-error",
      ],
      ctx,
    )
    let step_id = yaml_as_optional_string(fields.get("id"), "\{ctx}.id").unwrap_or(
      "step_\{index + 1}",
    )
    guard valid_identifier(step_id) && !step_ids.contains(step_id) else {
      raise InvalidWorkflow("\{ctx}: invalid or duplicate step id")
    }
    step_ids[step_id] = true
    let templates : Map[String, String] = Map([])
    let run = template_string(fields.get("run"), "\{ctx}.run")
    let uses = yaml_as_optional_string(fields.get("uses"), "\{ctx}.uses")
    guard (run is Some(_) && uses is None) || (run is None && uses is Some(_)) else {
      raise InvalidWorkflow("\{ctx} requires exactly one of run or uses")
    }
    let remote = uses is Some(action) && !action.has_prefix("moonhub/")
    if remote &&
      uses.unwrap().has_prefix("actions/checkout@") &&
      steps.any(step => step.uses == Some("moonhub/checkout@v1")) {
      raise InvalidWorkflow(
        "each job supports only one checkout step when using built-in checkout",
      )
    }
    let inputs : Map[String, String] = Map([])
    let input_secrets : Map[String, String] = Map([])
    let moonbit_version = if remote {
      let action = uses.unwrap()
      ignore(
        @actions.parse_reference(action) catch {
          @actions.InvalidAction(message) =>
            raise InvalidWorkflow("\{ctx}.uses: \{message}")
        },
      )
      check_fields(
        fields,
        [
          "id", "name", "uses", "with", "env", "timeout-minutes", "if", "continue-on-error",
        ],
        ctx,
      )
      let values = match fields.get("with") {
        None => Map([])
        Some(value) => yaml_as_obj(value, "\{ctx}.with")
      }
      guard values.length() <= 100 else {
        raise InvalidWorkflow("too many action inputs")
      }
      let seen : Map[String, Bool] = Map([])
      for key, value in values {
        guard @actions.valid_input_name(key) && !seen.contains(key.to_upper()) else {
          raise InvalidWorkflow("\{ctx}.with: invalid or duplicate input name")
        }
        seen[key.to_upper()] = true
        let value = match value {
          String(text) => text
          Integer(n) => n.to_string()
          Boolean(b) => if b { "true" } else { "false" }
          Real(_, repr~) => repr
          _ => raise InvalidWorkflow("\{ctx}.with.\{key} must be a scalar")
        }
        match secret_reference(value) {
          Some(secret) => {
            inputs[key] = ""
            input_secrets[@actions.input_env(key)] = secret
          }
          None => {
            validate_template(value, "\{ctx}.with.\{key}")
            if runtime_template(value) {
              templates["with:" + key] = value
              inputs[key] = ""
            } else {
              inputs[key] = value
            }
          }
        }
      }
      None
    } else if uses == Some("moonhub/setup-moonbit@v1") {
      check_fields(
        fields,
        ["id", "name", "uses", "with", "timeout-minutes"],
        ctx,
      )
      let inputs = match fields.get("with") {
        None => Map([])
        Some(value) => yaml_as_obj(value, "\{ctx}.with")
      }
      check_fields(inputs, ["version"], "\{ctx}.with")
      let requested = yaml_as_optional_string(
        inputs.get("version"),
        "\{ctx}.with.version",
      ).unwrap_or("latest")
      let version = match requested {
        "stable" => "latest"
        "bleeding" => "nightly"
        value => value
      }
      guard valid_moonbit_version(version) else {
        raise InvalidWorkflow(
          "\{ctx}.with.version must be latest, stable, nightly, bleeding, pre-release or a literal MoonBit version",
        )
      }
      Some(version)
    } else if uses is Some(_) {
      guard uses == Some("moonhub/checkout@v1") else {
        raise InvalidWorkflow("unsupported built-in MoonHub action")
      }
      guard !steps.any(step => {
        step.uses == Some("moonhub/checkout@v1") ||
        (step.uses is Some(action) && action.has_prefix("actions/checkout@"))
      }) else {
        raise InvalidWorkflow("each job supports only one checkout step")
      }
      check_fields(fields, ["id", "name", "uses", "timeout-minutes"], ctx)
      None
    } else {
      check_fields(
        fields,
        [
          "id", "name", "run", "env", "shell", "working-directory", "timeout-minutes",
          "if", "continue-on-error",
        ],
        ctx,
      )
      guard !run.unwrap_or("").trim().is_empty() else {
        raise InvalidWorkflow("\{ctx}.run requires a nonempty string")
      }
      if run.unwrap().contains("${{") {
        templates["run"] = run.unwrap()
      }
      None
    }
    let step_defaults = inherit_defaults(job_defaults, {
      shell: parse_shell(fields.get("shell"), "\{ctx}.shell"),
      working_directory: parse_directory(
        fields.get("working-directory"),
        "\{ctx}.working-directory",
      ),
    })
    guard uses is Some(_) ||
      step_defaults.shell != Some("pwsh") ||
      runs_on.contains("windows") else {
      raise InvalidWorkflow("\{ctx}.shell: pwsh requires Windows runner labels")
    }
    let explicit_env = if uses is Some(_) && !remote {
      Map([])
    } else {
      merge_env(
        Map([]),
        yaml_to_string_map(fields.get("env"), "\{ctx}.env"),
        windows=runs_on.contains("windows"),
      )
    }
    let step_env = if uses is Some(_) && !remote {
      Map([])
    } else {
      merge_env(env, explicit_env, windows=runs_on.contains("windows"))
    }
    let literal_env : Map[String, String] = Map([])
    let secret_env : Map[String, String] = input_secrets
    for name, value in step_env {
      match secret_reference(value) {
        Some(secret) => secret_env[name] = secret
        None =>
          if runtime_template(value) {
            templates["env:" + name] = value
          } else {
            literal_env[name] = value
          }
      }
    }
    for field in ["if", "continue-on-error"] {
      if fields.get(field) is Some(value) {
        let text = match value {
          String(text) => text
          Boolean(value) => value.to_string()
          _ =>
            raise InvalidWorkflow(
              "\{ctx}.\{field} requires a boolean or expression",
            )
        }
        validate_template(
          if text.contains("${{") {
            text
          } else {
            "${{" + text + "}}"
          },
          "\{ctx}.\{field}",
        )
        templates[field] = text
      }
    }
    steps.push({
      id: step_id,
      name: yaml_as_optional_string(fields.get("name"), "\{ctx}.name").unwrap_or(
        step_id,
      ),
      run: run.unwrap_or(""),
      uses,
      moonbit_version,
      remote,
      inputs,
      templates,
      shell: if uses is Some(_) {
        None
      } else {
        step_defaults.shell
      },
      working_directory: if uses is Some(_) {
        "."
      } else {
        step_defaults.working_directory.unwrap_or(".")
      },
      env: literal_env,
      env_overrides: explicit_env.keys().collect(),
      secret_env,
      timeout_minutes: parse_timeout(
        fields.get("timeout-minutes"),
        "\{ctx}.timeout-minutes",
      ),
    })
  }
  {
    id,
    name: yaml_as_optional_string(fields.get("name"), "\{ctx}.name").unwrap_or(
      id,
    ),
    needs: yaml_as_string_list(fields.get("needs"), "\{ctx}.needs"),
    runs_on,
    contents_read: read_permissions(
      fields.get("permissions"),
      contents_read,
      "\{ctx}.permissions",
    ),
    timeout_minutes: parse_timeout(
      fields.get("timeout-minutes"),
      "\{ctx}.timeout-minutes",
    ).unwrap_or(360),
    steps,
  }
}

///|
pub fn parse(source : String) -> Workflow raise InvalidWorkflow {
  let fields = yaml_as_obj(read_yaml(source), "workflow")
  check_fields(
    fields,
    ["name", "on", "env", "defaults", "jobs", "permissions"],
    "workflow",
  )
  ignore(parse_trigger(fields.get("on")))
  let env = yaml_to_string_map(fields.get("env"), "env")
  let defaults = parse_run_defaults(fields.get("defaults"), "defaults")
  let contents_read = read_permissions(
    fields.get("permissions"),
    true,
    "permissions",
  )
  guard fields.get("jobs") is Some(value) else {
    raise InvalidWorkflow("jobs is required")
  }
  let fields_jobs = yaml_as_obj(value, "jobs")
  guard !fields_jobs.is_empty() && fields_jobs.length() <= 16 else {
    raise InvalidWorkflow("workflow requires between 1 and 16 jobs")
  }
  let jobs : Array[Job] = []
  let mut step_count = 0
  for id, value in fields_jobs {
    let job = parse_job(id, value, env, defaults, contents_read)
    step_count += job.steps.length()
    jobs.push(job)
  }
  guard step_count <= 256 else {
    raise InvalidWorkflow("workflow exceeds 256 steps")
  }
  for job in jobs {
    for need in job.needs {
      guard need != job.id && fields_jobs.contains(need) else {
        raise InvalidWorkflow(
          "jobs.\{job.id}.needs references an unknown job or itself: \{need}",
        )
      }
    }
  }
  let visited : Map[String, Bool] = Map([])
  while visited.length() < jobs.length() {
    let before = visited.length()
    for job in jobs {
      if job.needs.all(need => visited.contains(need)) {
        visited[job.id] = true
      }
    }
    guard visited.length() > before else {
      raise InvalidWorkflow("job dependency cycle")
    }
  }
  let workflow : Workflow = {
    name: yaml_as_optional_string(fields.get("name"), "name").unwrap_or(""),
    jobs,
  }
  guard @utf8.encode(ToJson::to_json(workflow).stringify()).length() <= 1048576 else {
    raise InvalidWorkflow("normalized workflow exceeds 1 MiB")
  }
  workflow
}

///|
// Keep literal versions safe as both an installer argument and a download path.
fn valid_moonbit_version(version : String) -> Bool {
  ["latest", "nightly", "pre-release"].contains(version) ||
  (
    version.length() <= 128 &&
    version.get_char(0) is Some(first) &&
    first.is_ascii_digit() &&
    !version.contains("..") &&
    version
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() ||
      ch.is_ascii_digit() ||
      ch == '.' ||
      ch == '+' ||
      ch == '-'
    }) &&
    version.get_char(version.length() - 1) is Some(last) &&
    (last.is_ascii_alphabetic() || last.is_ascii_digit())
  )
}
