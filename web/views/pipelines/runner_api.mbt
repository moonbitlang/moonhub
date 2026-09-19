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
fn runner_error(err : Error) -> (Int, Json) {
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
    let (status, json) = (200, handler(req)) catch {
      err if @async.is_cancellation_error(err) => raise err
      err => runner_error(err)
    }
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
  ctx.get("/attempts/:id/source", async fn(req, res) {
    let archive = try {
      let id = @string.parse_int64(req.params.get("id").unwrap_or("")) catch {
        _ => raise @domain.BadRequest(message="invalid attempt id")
      }
      guard id > 0L else {
        raise @domain.BadRequest(message="invalid attempt id")
      }
      let token = bearer_token(req)
      coordinator.authenticate_attempt(id, token)
      guard root is Some(root) else {
        raise @domain.NotFound(message="source checkout is unavailable")
      }
      coordinator.read_source(root, id, token)
    } catch {
      err if @async.is_cancellation_error(err) => raise err
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
  ctx.post(
    "/claims",
    json_handler(req => {
      let token = bearer_token(req)
      coordinator.authenticate_provider(token)
      let json = request_json(req, ["version", "request_id", "attempt_token"])
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
  for operation in ["start", "heartbeat", "logs", "steps", "complete"] {
    ctx.post(
      "/attempts/:id/\{operation}",
      json_handler(req => {
        let id = @string.parse_int64(req.params.get("id").unwrap_or("")) catch {
          _ => raise @domain.BadRequest(message="invalid attempt id")
        }
        guard id > 0L else {
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
              "version", "conclusion", "last_log_sequence",
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
