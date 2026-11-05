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
  run_backend_worker(base, token, {
    os: if @platform.windows() {
      "windows"
    } else {
      "linux"
    },
    fresh_each_job: false,
    initialize: () => {
      wait_for_docker(base)
      cleanup_stale_containers(base)
      cleanup_stale_workspaces(base)
    },
    prepare: current => ensure_runner_image(current),
    health: () => (),
    execute: (current, assignment, credential) => {
      execute_assignment(current, assignment, credential)
    },
    cleanup: () => (),
  })
}

///|
async fn run_backend_worker(
  base : Options,
  token : String,
  backend : WorkerBackend,
) -> Unit {
  validate_origin(base.server, base.allow_http)
  let state = Ref("starting")
  let applied = Ref("0")
  let latest : Ref[@protocol.WorkerSnapshot?] = Ref(None)
  @platform.private_directory(base.workspace_root)
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
    defer @async.protect_from_cancel(backend.cleanup)
    (backend.initialize)()
    let current = Ref(base)
    let prepared = Ref(false)
    for ;; {
      guard latest.val is Some(snapshot) else {
        @async.sleep(500)
        continue
      }
      if snapshot.draining {
        state.val = "starting"
        break
      }
      if snapshot.paused {
        state.val = "starting"
        if prepared.val {
          (backend.cleanup)()
          prepared.val = false
        }
        @async.sleep(base.poll_ms)
        continue
      }
      if !prepared.val || applied.val != snapshot.config_revision {
        state.val = "starting"
        current.val = configured_options(base, snapshot.config)
        (backend.prepare)(current.val)
        applied.val = snapshot.config_revision
        prepared.val = true
      }
      (backend.health)()
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
        state.val = "starting"
        break
      }
      if ready.paused || ready.config_revision != applied.val {
        @async.sleep(base.poll_ms)
        continue
      }
      let assignment = claim(current.val, token, runner_os=backend.os) catch {
        Rejected(code) if code == 401 || code == 403 => raise Rejected(code)
        _ => {
          @async.sleep(base.poll_ms)
          continue
        }
      }
      match assignment {
        None => @async.sleep(base.poll_ms)
        Some(claimed) => {
          validate_assignment(claimed.assignment, runner_os=backend.os)
          state.val = "busy"
          (backend.execute)(
            current.val,
            claimed.assignment,
            claimed.attempt_token,
          ) catch {
            InvalidConfiguration(message) => {
              state.val = "failed"
              raise InvalidConfiguration(message)
            }
            _ => {
              state.val = "failed"
              raise CleanupFailure
            }
          }
          if backend.fresh_each_job {
            state.val = "starting"
            prepared.val = false
          } else {
            state.val = "ready"
          }
        }
      }
    }
    (backend.cleanup)()
    state.val = "drained"
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
