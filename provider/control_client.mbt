///|
pub async fn control_request(
  server : String,
  path : String,
  token : String,
  body : Json,
  allow_http~ : Bool = false,
) -> Json {
  validate_origin(server, allow_http)
  @async.with_timeout(15000, () => {
    let client = @http.Client(server)
    defer client.close()
    let response = client.post("/-/runner-api/v1" + path, body.stringify(), extra_headers={
      "Authorization": "Bearer " + token,
      "Content-Type": "application/json",
    })
    guard response.code == 200 else { raise Rejected(response.code) }
    let bytes : Array[Byte] = []
    while client.read_some(max_len=4096) is Some(chunk) {
      guard bytes.length() + chunk.length() <= 1048576 else {
        raise InvalidConfiguration("Control response too large.")
      }
      for byte in chunk {
        bytes.push(byte)
      }
    }
    @json.parse(@utf8.decode(Bytes::from_array(bytes)))
  })
}

///|
fn configured_options(
  base : Options,
  config : Map[String, String],
) -> Options raise ProviderError {
  let memory = config.get("memory_mib").unwrap_or("4096")
  let cpus = config.get("cpus").unwrap_or("2")
  guard @protocol.parse_decimal(memory) is Some(mem) &&
    mem >= 256L &&
    mem <= 1048576L &&
    @protocol.parse_decimal(cpus) is Some(cpu) &&
    cpu >= 1L &&
    cpu <= 256L else {
    raise InvalidConfiguration("Invalid task limits.")
  }
  let image = config.get("runner_image").unwrap_or(base.runner_image)
  let options = { ..base, runner_image: image, memory: memory + "m", cpus, }
  validate_options(options)
  options
}

///|
pub async fn run_worker(base : Options, token : String) -> Unit {
  validate_origin(base.server, base.allow_http)
  let state = Ref("starting")
  let applied = Ref("0")
  let latest : Ref[@protocol.WorkerSnapshot?] = Ref(None)
  @fs.mkdir(
    base.workspace_root,
    recursive=true,
    permission=0o700,
    allow_exist=true,
  )
  errdefer (@async.protect_from_cancel(() => {
    let request : @protocol.WorkerSyncRequest = {
      version: 1,
      state: "failed",
      applied_revision: applied.val,
    }
    ignore(
      control_request(
        base.server,
        "/workers/sync",
        token,
        ToJson::to_json(request),
        allow_http=base.allow_http,
      ),
    )
  }) catch {
    _ => ()
  })
  @async.with_task_group(group => {
    group.spawn_bg(() => {
      for ;; {
        let request : @protocol.WorkerSyncRequest = {
          version: 1,
          state: state.val,
          applied_revision: applied.val,
        }
        try {
          let response : @protocol.WorkerSnapshot = @json.from_json(
            control_request(
              base.server,
              "/workers/sync",
              token,
              ToJson::to_json(request),
              allow_http=base.allow_http,
            ),
          )
          latest.val = Some(response)
        } catch {
          Rejected(code) if code == 401 || code == 403 => raise Rejected(code)
          _ => ()
        }
        @async.sleep(5000)
      }
    })
    wait_for_docker(base)
    cleanup_stale_containers(base)
    cleanup_stale_workspaces(base)
    let current = Ref(base)
    for ;; {
      guard latest.val is Some(snapshot) else {
        @async.sleep(500)
        continue
      }
      if snapshot.draining {
        state.val = "drained"
        break
      }
      if applied.val != snapshot.config_revision {
        state.val = "starting"
        current.val = configured_options(base, snapshot.config)
        ensure_runner_image(current.val)
        applied.val = snapshot.config_revision
      }
      state.val = "ready"
      // Acknowledge readiness only after both cleanup and configuration finish.
      let request : @protocol.WorkerSyncRequest = {
        version: 1,
        state: "ready",
        applied_revision: applied.val,
      }
      let ready : @protocol.WorkerSnapshot = @json.from_json(
        control_request(
          base.server,
          "/workers/sync",
          token,
          ToJson::to_json(request),
          allow_http=base.allow_http,
        ),
      ) catch {
        Rejected(code) if code == 401 || code == 403 => raise Rejected(code)
        _ => {
          @async.sleep(base.poll_ms)
          continue
        }
      }
      latest.val = Some(ready)
      if ready.draining {
        state.val = "drained"
        break
      }
      if ready.paused || ready.config_revision != applied.val {
        @async.sleep(base.poll_ms)
        continue
      }
      let assignment = claim(current.val, token) catch {
        Rejected(code) if code == 401 || code == 403 => raise Rejected(code)
        _ => {
          @async.sleep(base.poll_ms)
          continue
        }
      }
      match assignment {
        None => @async.sleep(base.poll_ms)
        Some(claimed) => {
          validate_assignment(claimed.assignment)
          state.val = "busy"
          execute_assignment(
            current.val,
            claimed.assignment,
            claimed.attempt_token,
          ) catch {
            _ => {
              state.val = "failed"
              raise CleanupFailure
            }
          }
          state.val = "ready"
        }
      }
    }
    let request : @protocol.WorkerSyncRequest = {
      version: 1,
      state: state.val,
      applied_revision: applied.val,
    }
    ignore(
      control_request(
        base.server,
        "/workers/sync",
        token,
        ToJson::to_json(request),
        allow_http=base.allow_http,
      ),
    )
    group.return_immediately(())
  })
}
