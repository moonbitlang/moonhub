///|
fn validate_server(
  server : String,
  allow_http : Bool,
) -> Unit raise RunnerError {
  let prefix = if server.has_prefix("https://") {
    8
  } else if allow_http && server.has_prefix("http://") {
    7
  } else {
    raise InvalidConfiguration(
      "runner requires HTTPS; --allow-http is only for trusted development networks",
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
      "server must be an origin without credentials, path, query or fragment",
    )
  }
}

///|
async fn post_once(
  server : String,
  id : String,
  token : String,
  operation : String,
  body : Json,
) -> @protocol.LeaseState {
  let client = @http.Client(server)
  defer client.close()
  let response = client.post(
    "/-/runner-api/v1/attempts/\{id}/\{operation}",
    body.stringify(),
    extra_headers={
      "Authorization": "Bearer " + token,
      "Content-Type": "application/json",
    },
  )
  guard response.code == 200 else { raise Rejected(response.code) }
  let bytes : Array[Byte] = []
  while client.read_some(max_len=4096) is Some(chunk) {
    guard bytes.length() + chunk.length() <= 65536 else {
      raise InvalidResponse
    }
    for byte in chunk {
      bytes.push(byte)
    }
  }
  let state : @protocol.LeaseState = @json.from_json(
    @json.parse(@utf8.decode(Bytes::from_array(bytes))),
  ) catch {
    _ => raise InvalidResponse
  }
  guard state.version == @protocol.version &&
    state.attempt_id == id &&
    ["leased", "running", "completed"].contains(state.state) else {
    raise InvalidResponse
  }
  state
}

///|
async fn post_retry(
  server : String,
  id : String,
  token : String,
  operation : String,
  body : Json,
  until : Int64,
) -> (@protocol.LeaseState, Int64) {
  for ;; {
    let sent = monotonic_ms()
    guard sent < until else { raise TransportFailure }
    let timeout = Int64::min(5000L, until - sent).to_int()
    let result = Some(
      @async.with_timeout(timeout, () => {
        post_once(server, id, token, operation, body)
      }),
    ) catch {
      Rejected(code) if code < 500 && code != 429 => raise Rejected(code)
      InvalidResponse => raise InvalidResponse
      _ => None
    }
    if result is Some(state) {
      return (state, sent)
    }
    guard monotonic_ms() + 100L < until else { raise TransportFailure }
    @async.sleep(100)
  }
}

///|
async fn fetch_source(server : String, id : String, token : String) -> Bytes {
  let client = @http.Client(server)
  defer client.close()
  let response = client.get("/-/runner-api/v1/attempts/\{id}/source", extra_headers={
    "Authorization": "Bearer " + token,
  })
  guard response.code == 200 else { raise Rejected(response.code) }
  let bytes : Array[Byte] = []
  while client.read_some(max_len=8192) is Some(chunk) {
    guard bytes.length().to_int64() + chunk.length().to_int64() <=
      @protocol.max_source_bytes else {
      raise InvalidResponse
    }
    for byte in chunk {
      bytes.push(byte)
    }
  }
  Bytes::from_array(bytes)
}

///|
fn Runtime::accept(
  self : Runtime,
  state : @protocol.LeaseState,
  sent : Int64,
) -> Unit raise {
  guard state.version == @protocol.version &&
    state.attempt_id == self.assignment.attempt_id &&
    state.execution_id == self.execution_id else {
    raise InvalidResponse
  }
  let lease_until_ms = parse_runner_int64(state.lease_until_ms)
  let server_time_ms = parse_runner_int64(state.server_time_ms)
  let deadline_ms = parse_runner_int64(state.deadline_ms)
  guard parse_runner_int64(state.log_sequence) <= @protocol.max_log_chunks else {
    raise InvalidResponse
  }
  if state.state == "completed" {
    return
  }
  guard lease_until_ms >= server_time_ms &&
    lease_until_ms - server_time_ms <= @protocol.lease_ms else {
    raise InvalidResponse
  }
  let lease = sent + (lease_until_ms - server_time_ms) - 1000L
  self.lease_until = lease
  if deadline_ms > 0L {
    let remaining = deadline_ms - server_time_ms
    guard remaining <= self.assignment.job.timeout_minutes.to_int64() * 60000L else {
      raise InvalidResponse
    }
    let deadline = sent + Int64::max(0L, remaining) - 1000L
    self.deadline = Int64::min(self.deadline, deadline)
  }
  if state.cancel_requested {
    self.stopped = "cancelled"
  }
}

///|
fn Runtime::check_live(self : Runtime) -> Unit raise RunnerError {
  if !self.stopped.is_empty() {
    raise Stopped(self.stopped)
  }
  if monotonic_ms() >= self.deadline {
    raise Stopped("timed_out")
  }
  if monotonic_ms() >= self.lease_until {
    raise Stopped("lost")
  }
}

///|
async fn Runtime::request(
  self : Runtime,
  operation : String,
  body : Json,
) -> @protocol.LeaseState {
  let until = if self.reporting_until > 0L {
    self.reporting_until
  } else {
    self.lease_until
  }
  let (state, sent) = (self.post)(operation, body, until)
  self.accept(state, sent)
  if state.state == "completed" && operation != "complete" {
    raise Stopped("lost")
  }
  state
}
