///|
#derive(Debug, ToJson, FromJson)
pub(all) struct Container {
  image : String
  env : Map[String, String]
  ports : Array[String]
  options : Array[String]
}

///|
#derive(Debug, ToJson)
pub(all) struct ContainerPlan {
  job : Container?
  services : Map[String, Container]
}

///|
pub impl @json.FromJson for ContainerPlan with fn from_json(json, path) {
  guard json is Object(fields) else {
    raise @json.JsonDecodeError((path, "invalid container plan"))
  }
  {
    job: match fields.get("job") {
      None | Some(Null) => None
      Some(value) => Some(@json.from_json(value, path=path.add_key("job")))
    },
    services: @json.from_json(
      fields.get("services").unwrap_or(({} : Json)),
      path=path.add_key("services"),
    ),
  }
}

///|
pub fn valid_container_image(image : String) -> Bool {
  image.length() <= 512 &&
  image.iter().next() is Some(first) &&
  (first.is_ascii_alphabetic() || first.is_ascii_digit()) &&
  image
  .iter()
  .all(c => {
    c.is_ascii_alphabetic() ||
    c.is_ascii_digit() ||
    ['.', '_', '-', ':', '/', '@'].contains(c)
  }) &&
  !image.contains("..") &&
  !image.contains("://")
}

///|
// Docker receives arguments directly, never a shell command. Only resource,
// execution-user and health-check options are accepted; host mounts, networking,
// privileges, daemon selection and arbitrary config files are not configurable.
pub fn docker_options(source : String) -> Array[String] raise InvalidAction {
  guard source.length() <= 4096 else {
    raise InvalidAction("container options exceed 4096 characters")
  }
  let result : Array[String] = []
  let mut token = StringBuilder()
  let mut quote : Char? = None
  let mut escaped = false
  let mut started = false
  for c in source {
    if escaped {
      token.write_char(c)
      escaped = false
      started = true
      continue
    }
    if c == '\\' && quote != Some('\'') {
      escaped = true
      started = true
      continue
    }
    if quote is Some(q) {
      if c == q {
        quote = None
      } else {
        token.write_char(c)
      }
      continue
    }
    if c == '\'' || c == '"' {
      quote = Some(c)
      started = true
      continue
    }
    if [' ', '\t', '\n', '\r'].contains(c) {
      if started {
        result.push(token.to_string())
        token = StringBuilder()
        started = false
      }
    } else {
      token.write_char(c)
      started = true
    }
  }
  guard !escaped && quote is None else {
    raise InvalidAction("unterminated container option quoting")
  }
  if started {
    result.push(token.to_string())
  }
  guard result.length() % 2 == 0 && result.length() <= 32 else {
    raise InvalidAction("container options require flag/value pairs")
  }
  for i in 0..<(result.length() / 2) {
    let key = result[i * 2]
    let value = result[i * 2 + 1]
    guard [
        "--cpus", "--memory", "--memory-swap", "--shm-size", "--user", "--health-cmd",
        "--health-interval", "--health-timeout", "--health-retries", "--health-start-period",
      ].contains(key) &&
      !value.is_empty() &&
      !value.contains("\u{0000}") &&
      !value.contains("\n") &&
      !value.contains("\r") &&
      !value.has_prefix("-") else {
      raise InvalidAction("unsupported container option")
    }
  }
  result
}

///|
pub fn valid_container_port(port : String) -> Bool {
  let port = port
    .strip_suffix("/tcp")
    .unwrap_or_else(() => port.strip_suffix("/udp").unwrap_or(port))
  let parts = port.split(":").collect()
  parts.length() >= 1 &&
  parts.length() <= 2 &&
  parts.all(value => {
    value.length() > 0 &&
    value.length() <= 5 &&
    value.iter().all(c => c.is_ascii_digit()) &&
    ({
      let n = value.iter().fold(init=0, (n, c) => n * 10 + c.to_int() - 48)
      n >= 1 && n <= 65535
    })
  })
}
