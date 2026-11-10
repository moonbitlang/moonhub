///|
priv suberror PayloadTooLarge {
  PayloadTooLarge
}

///|
fn bearer_token(req : @moonback.Request) -> String raise {
  let headers = req.headers.get_all("authorization")
  guard headers.length() == 1 && headers[0].length() <= 80 else {
    raise @domain.Unauthorized(message="runner bearer credential required")
  }
  guard headers[0].split_once(" ") is Some((scheme, token)) &&
    scheme.to_lower() == "bearer" else {
    raise @domain.Unauthorized(message="runner bearer credential required")
  }
  token.to_owned()
}

///|
async fn request_json(req : @moonback.Request, allowed : Array[String]) -> Json {
  let content_type = req.headers.get("content-type").unwrap_or("")
  let mime = content_type
    .split_once(";")
    .map_or(content_type, pair => pair.0)
    .trim()
    .to_lower()
  guard mime == "application/json" else {
    raise @domain.BadRequest(message="application/json required")
  }
  if req.headers.get("content-length") is Some(length) {
    let length = @string.parse_int64(length) catch {
      _ => raise @domain.BadRequest(message="invalid content length")
    }
    guard length >= 0L && length <= 65536L else { raise PayloadTooLarge }
  }
  let bytes : Array[Byte] = []
  let reader = req.body.reader()
  @async.with_timeout(
    10000,
    () => {
      while reader.read_some(max_len=4096) is Some(chunk) {
        guard bytes.length() + chunk.length() <= 65536 else {
          raise PayloadTooLarge
        }
        for byte in chunk {
          bytes.push(byte)
        }
      }
    },
    error=@domain.BadRequest(message="request body timed out"),
  )
  let text = @utf8.decode(Bytes::from_array(bytes)) catch {
    _ => raise @domain.BadRequest(message="request body must be UTF-8")
  }
  let json = @json.parse(text) catch {
    _ => raise @domain.BadRequest(message="invalid JSON body")
  }
  guard json is Object(fields) else {
    raise @domain.BadRequest(message="JSON object required")
  }
  for key, _ in fields {
    guard allowed.contains(key) else {
      raise @domain.BadRequest(message="unsupported request field")
    }
  }
  json
}

///|
fn runner_error(err : Error) -> (Int32, Json) {
  let (status, code, message) = match err {
    @domain.Unauthorized(message~) => (401, "unauthorized", message)
    @domain.Forbidden(message~) => (403, "forbidden", message)
    @domain.NotFound(message~) => (404, "not_found", message)
    @domain.BadRequest(message~) => (400, "invalid_request", message)
    @pipeline.Conflict(message) => (409, "conflict", message)
    @pipeline.LogLimit | PayloadTooLarge =>
      (413, "limit_exceeded", "request or log limit exceeded")
    _ => (500, "internal_error", "runner request failed")
  }
  (status, { "version": 1, "error": { "code": code, "message": message } })
}

///|
fn json_handler(
  handler : async (@moonback.Request) -> Json,
) -> @moonback.Handler {
  (req, res) => {
    let (status, json) = (200, handler(req)) catch { err => runner_error(err) }
    // Closing error connections avoids draining an oversized or unauthorized body.
    res.send_json(json, status~, headers={
      "Cache-Control": "no-store",
      "Connection": "close",
    })
  }
}

///|
pub let runner_api_module : @moonback.Module = Module(ctx => {
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  let root = ctx.resolve(@web_context.config_root)
  ctx.post(
    "/providers/register",
    json_handler(req => {
      let token = bearer_token(req)
      let payload = request_json(req, [
        "version", "name", "mode", "provider_token", "schema", "defaults",
      ])
      let request : @protocol.RegisterProviderRequest = @json.from_json(payload) catch {
        _ => raise @domain.BadRequest(message="Invalid registration request.")
      }
      ToJson::to_json(coordinator.register_runner(token, request))
    }),
  )
  ctx.post(
    "/providers/sync",
    json_handler(req => {
      let token = bearer_token(req)
      let payload = request_json(req, [
        "version", "controller_id", "observed_revision", "applied_revision", "status",
        "schema", "defaults",
      ])
      let request : @protocol.ProviderSyncRequest = @json.from_json(payload) catch {
        _ => raise @domain.BadRequest(message="Invalid provider sync.")
      }
      ToJson::to_json(coordinator.sync_provider(token, request))
    }),
  )
  ctx.post(
    "/workers/register",
    json_handler(req => {
      let token = bearer_token(req)
      let payload = request_json(req, ["version", "key", "token"])
      let request : @protocol.WorkerRegistration = @json.from_json(payload) catch {
        _ => raise @domain.BadRequest(message="Invalid worker registration.")
      }
      ToJson::to_json(coordinator.register_worker(token, request))
    }),
  )
  ctx.post(
    "/workers/sync",
    json_handler(req => {
      let token = bearer_token(req)
      let payload = request_json(req, ["version", "state", "applied_revision"])
      let request : @protocol.WorkerSyncRequest = @json.from_json(payload) catch {
        _ => raise @domain.BadRequest(message="Invalid worker sync.")
      }
      ToJson::to_json(coordinator.sync_worker(token, request))
    }),
  )
  ctx.post(
    "/workers/:id/drain",
    json_handler(req => {
      let token = bearer_token(req)
      let payload = request_json(req, ["version"])
      let request : @protocol.VersionRequest = @json.from_json(payload) catch {
        _ => raise @domain.BadRequest(message="Invalid drain request.")
      }
      guard request.version == 1 else {
        raise @domain.BadRequest(message="Unsupported protocol version.")
      }
      let id = @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "worker"),
      )
      coordinator.drain_worker(token, id)
      { "version": 1 }
    }),
  )
  ctx.get("/attempts/:id/source", async fn(req, res) {
    let archive = try {
      guard @protocol.parse_decimal(
          req.params.get("id").unwrap_or("").to_owned(),
        )
        is Some(id) &&
        id > 0L else {
        raise @domain.BadRequest(message="invalid attempt id")
      }
      let token = bearer_token(req)
      coordinator.authenticate_attempt(id, token)
      guard root is Some(root) else {
        raise @domain.NotFound(message="source checkout is unavailable")
      }
      coordinator.read_source(root, id, token)
    } catch {
      err => {
        let (status, json) = runner_error(err)
        res.send_json(json, status~, headers={
          "Cache-Control": "no-store",
          "Connection": "close",
        })
        return
      }
    }
    let writer = res.respond(status=200, headers={
      "Cache-Control": "no-store",
      "Content-Type": "application/x-tar",
      "Content-Length": archive.length().to_string(),
    })
    writer.write(archive)
  })
  ctx.get("/attempts/:id/source-bundle", async fn(req, res) {
    let archive = try {
      guard @protocol.parse_decimal(
          req.params.get("id").unwrap_or("").to_owned(),
        )
        is Some(id) &&
        id > 0L else {
        raise @domain.BadRequest(message="invalid attempt id")
      }
      let token = bearer_token(req)
      coordinator.authenticate_attempt(id, token)
      guard root is Some(root) else {
        raise @domain.NotFound(message="source checkout is unavailable")
      }
      coordinator.read_source_bundle(root, id, token)
    } catch {
      err => {
        let (status, json) = runner_error(err)
        res.send_json(json, status~, headers={
          "Cache-Control": "no-store",
          "Connection": "close",
        })
        return
      }
    }
    let writer = res.respond(status=200, headers={
      "Cache-Control": "no-store",
      "Content-Type": "application/x-git-bundle",
      "Content-Length": archive.length().to_string(),
    })
    writer.write(archive)
  })
  ctx.post(
    "/attempts/:id/artifact-runtime",
    json_handler(req => {
      let id = @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "attempt"),
      )
      let token = bearer_token(req)
      let payload = request_json(req, ["version", "execution_id", "origin"])
      let request : @protocol.ArtifactRuntimeRequest = @json.from_json(payload) catch {
        _ =>
          raise @domain.BadRequest(message="invalid artifact runtime request")
      }
      ToJson::to_json(coordinator.artifact_runtime(id, token, request))
    }),
  )
  ctx.post(
    "/attempts/:id/oidc-runtime",
    json_handler(req => {
      let id = @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "attempt"),
      )
      let token = bearer_token(req)
      let payload = request_json(req, ["version", "execution_id"])
      let request : @protocol.OidcRuntimeRequest = @json.from_json(payload) catch {
        _ => raise @domain.BadRequest(message="invalid OIDC runtime request")
      }
      ToJson::to_json(coordinator.oidc_runtime(id, token, request))
    }),
  )
  ctx.post(
    "/claims",
    json_handler(req => {
      let token = bearer_token(req)
      let json = request_json(req, [
        "version", "request_id", "attempt_token", "runner_os",
      ])
      let request : @protocol.ClaimRequest = @json.from_json(json) catch {
        _ => raise @domain.BadRequest(message="invalid claim request")
      }
      let assignment = coordinator.claim(token, request)
      {
        "version": 1,
        "assignment": match assignment {
          Some(assignment) => ToJson::to_json(assignment)
          None => Json::null()
        },
      }
    }),
  )
  ctx.post(
    "/attempts/:id/secrets",
    json_handler(req => {
      let id = @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "attempt"),
      )
      let token = bearer_token(req)
      coordinator.authenticate_attempt(id, token)
      let payload = request_json(req, ["version", "execution_id", "step_id"])
      let request : @protocol.SecretRequest = @json.from_json(payload) catch {
        _ => raise @domain.BadRequest(message="Invalid secret request.")
      }
      ToJson::to_json(coordinator.step_secrets(id, token, request))
    }),
  )
  for operation in ["start", "heartbeat", "logs", "steps", "complete"] {
    ctx.post(
      "/attempts/:id/\{operation}",
      json_handler(req => {
        guard @protocol.parse_decimal(
            req.params.get("id").unwrap_or("").to_owned(),
          )
          is Some(id) &&
          id > 0L else {
          raise @domain.BadRequest(message="invalid attempt id")
        }
        let token = bearer_token(req)
        coordinator.authenticate_attempt(id, token)
        let state = match operation {
          "start" => {
            let json = request_json(req, ["version", "execution_id"])
            if json is Object(fields) && fields.contains("execution_id") {
              let request : @protocol.StartRequest = @json.from_json(json) catch {
                _ => raise @domain.BadRequest(message="invalid start request")
              }
              guard !request.execution_id.is_empty() else {
                raise @domain.BadRequest(message="execution id is empty")
              }
              coordinator.start(
                id,
                token,
                request.version,
                execution_id=request.execution_id,
              )
            } else {
              let request : @protocol.VersionRequest = @json.from_json(json) catch {
                _ => raise @domain.BadRequest(message="invalid start request")
              }
              coordinator.start(id, token, request.version)
            }
          }
          "heartbeat" => {
            let json = request_json(req, ["version"])
            let request : @protocol.VersionRequest = @json.from_json(json) catch {
              _ => raise @domain.BadRequest(message="invalid version request")
            }
            coordinator.heartbeat(id, token, request.version)
          }
          "steps" => {
            let json = request_json(req, [
              "version", "step_id", "state", "exit_code",
            ])
            let request : @protocol.StepRequest = @json.from_json(json) catch {
              _ => raise @domain.BadRequest(message="invalid step request")
            }
            coordinator.update_step(id, token, request)
          }
          "logs" => {
            let json = request_json(req, [
              "version", "sequence", "step_id", "stream", "text",
            ])
            let request : @protocol.LogRequest = @json.from_json(json) catch {
              _ => raise @domain.BadRequest(message="invalid log request")
            }
            coordinator.append_log(id, token, request)
          }
          _ => {
            let json = request_json(req, [
              "version", "conclusion", "last_log_sequence", "outputs",
            ])
            let request : @protocol.CompleteRequest = @json.from_json(json) catch {
              _ =>
                raise @domain.BadRequest(message="invalid completion request")
            }
            coordinator.complete(id, token, request)
          }
        }
        ToJson::to_json(state)
      }),
    )
  }
})
