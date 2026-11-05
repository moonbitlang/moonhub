///|
fn validate_origin(
  server : String,
  allow_http : Bool,
) -> Unit raise ProviderError {
  let prefix = if server.has_prefix("https://") {
    8
  } else if allow_http && server.has_prefix("http://") {
    7
  } else {
    raise InvalidConfiguration(
      "provider requires HTTPS; plain HTTP needs --allow-http",
    )
  }
  let authority = server[prefix:]
  guard !authority.is_empty() &&
    authority.length() <= 300 &&
    !authority.contains("/") &&
    !authority.contains("@") &&
    !authority.contains("?") &&
    !authority.contains("#") &&
    authority.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) else {
    raise InvalidConfiguration(
      "server must be an origin without credentials or a path",
    )
  }
}

///|
fn validate_options(options : Options) -> Unit raise ProviderError {
  validate_origin(options.server, options.allow_http)
  validate_origin(options.runner_server, options.allow_http)
  guard options.network != "host" && !options.network.has_prefix("container:") else {
    raise InvalidConfiguration("runner requires its own network namespace")
  }
  guard !options.runner_image.is_empty() &&
    options.runner_image.length() <= 256 &&
    options.runner_image
    .iter()
    .all(ch => {
      ch.to_int() >= 33 &&
      ch.to_int() < 127 &&
      ch != ' ' &&
      ch != '\t' &&
      ch != '\n' &&
      ch != '\r'
    }) else {
    raise InvalidConfiguration("invalid runner image")
  }
  guard !options.docker.is_empty() &&
    !options.docker_host.contains("\n") &&
    !options.network.contains("\n") &&
    options.poll_ms >= 100 &&
    options.poll_ms <= 60000 &&
    options.pids_limit >= 16 &&
    options.pids_limit <= 4096 &&
    !options.memory.is_empty() &&
    !options.cpus.is_empty() else {
    raise InvalidConfiguration("invalid provider limits or polling interval")
  }
  if !options.runner_host.is_empty() || !options.runner_host_ip.is_empty() {
    guard !options.runner_host.is_empty() && !options.runner_host_ip.is_empty() else {
      raise InvalidConfiguration(
        "runner host and address must be provided together",
      )
    }
    guard options.runner_host
      .iter()
      .all(ch => {
        ch.is_ascii_alphabetic() ||
        ch.is_ascii_digit() ||
        ch == '-' ||
        ch == '.'
      }) &&
      options.runner_host_ip
      .iter()
      .all(ch => {
        ch.is_ascii_alphabetic() ||
        ch.is_ascii_digit() ||
        ch == '.' ||
        ch == ':'
      }) else {
      raise InvalidConfiguration("invalid runner host mapping")
    }
  }
}

///|
async fn post_claim(
  options : Options,
  provider_token : String,
  request_id : String,
  attempt_token : String,
  runner_os : String,
) -> @protocol.Assignment? {
  let client = @http.Client(options.server)
  defer client.close()
  let request : @protocol.ClaimRequest = {
    runner_os: Some(runner_os),
    version: @protocol.version,
    request_id,
    attempt_token,
  }
  let response = client.post(
    "/-/runner-api/v1/claims",
    ToJson::to_json(request).stringify(),
    extra_headers={
      "Authorization": "Bearer " + provider_token,
      "Content-Type": "application/json",
    },
  )
  guard response.code == 200 else {
    if response.code >= 500 || response.code == 429 {
      raise TransportFailure
    }
    raise Rejected(response.code)
  }
  let bytes : Array[Byte] = []
  while client.read_some(max_len=4096) is Some(chunk) {
    guard bytes.length() + chunk.length() <= 65536 else {
      raise InvalidConfiguration("claim response is too large")
    }
    for byte in chunk {
      bytes.push(byte)
    }
  }
  let json = @json.parse(@utf8.decode(Bytes::from_array(bytes))) catch {
    _ => raise InvalidConfiguration("claim response is invalid JSON")
  }
  guard json is Object(fields) else {
    raise InvalidConfiguration("claim response is not an object")
  }
  guard fields.get("version") is Some(Number(_, ..)) else {
    raise InvalidConfiguration("claim response has no protocol version")
  }
  match fields.get("assignment") {
    Some(Null) | None => None
    Some(value) => {
      let assignment : @protocol.Assignment = @json.from_json(value) catch {
        _ =>
          raise InvalidConfiguration("claim response has an invalid assignment")
      }
      Some(assignment)
    }
  }
}

///|
async fn claim(
  options : Options,
  provider_token : String,
  runner_os~ : String = if @platform.windows() { "windows" } else { "linux" },
) -> ClaimedAssignment? {
  let request_id = random_hex(16)
  let attempt_token = random_hex(32)
  let deadline = @env.now().reinterpret_as_int64() + 10000L
  for ;; {
    let result = Some(
      post_claim(options, provider_token, request_id, attempt_token, runner_os),
    ) catch {
      Rejected(code) if code == 401 || code == 403 => raise Rejected(code)
      Rejected(code) => raise Rejected(code)
      _ => None
    }
    if result is Some(assignment) {
      match assignment {
        Some(assignment) => return Some({ assignment, attempt_token, })
        None => return None
      }
    }
    guard @env.now().reinterpret_as_int64() < deadline else {
      raise TransportFailure
    }
    @async.sleep(100)
  }
}
