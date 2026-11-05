///|
fn artifact_error(err : Error) -> (Int32, Json) {
  let (status, json) = runner_error(err)
  let code = match status {
    401 => "unauthenticated"
    403 => "permission_denied"
    404 => "not_found"
    409 => "already_exists"
    413 => "resource_exhausted"
    400 => "invalid_argument"
    _ => "internal"
  }
  let message = match json {
    { "error": { "message": String(text), .. }, .. } => text
    _ => "artifact request failed"
  }
  (status, { "code": code, "msg": message })
}

///|
fn artifact_bearer(req : @moonback.Request) -> String raise {
  let all = req.headers.get_all("authorization")
  guard all.length() == 1 &&
    all[0].length() <= 4103 &&
    all[0].strip_prefix("Bearer ") is Some(token) else {
    raise @domain.Unauthorized(message="artifact runtime bearer required")
  }
  token.to_owned()
}

///|
pub let artifact_rpc_module : @moonback.Module = Module(ctx => {
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  ctx.post("/:operation", async fn(req, res) {
    let (status, json) = try {
      let token = artifact_bearer(req)
      let payload = request_json(req, [
        "workflow_run_backend_id", "workflow_job_run_backend_id", "name", "expires_at",
        "version", "size", "hash", "name_filter", "id_filter",
      ])
      (
        200,
        coordinator.artifact_rpc(
          token,
          @web_context.required_param(req, "operation", "operation"),
          payload,
        ),
      )
    } catch {
      err => artifact_error(err)
    }
    res.send_json(json, status~, headers={
      "Cache-Control": "no-store",
      "Connection": "close",
    })
  })
})

///|
async fn artifact_request_bytes(
  req : @moonback.Request,
  limit : Int32,
) -> Bytes {
  let bytes = @buffer.Buffer()
  if req.headers.get("content-length") is Some(text) {
    let size = @string.parse_int64(text) catch {
      _ => raise @domain.BadRequest(message="invalid content length")
    }
    guard size >= 0L && size <= limit.to_int64() else { raise PayloadTooLarge }
  }
  let reader = req.body.reader()
  @async.with_timeout(30000, () => {
    while reader.read_some(max_len=65536) is Some(chunk) {
      guard bytes.length() + chunk.length() <= limit else {
        raise PayloadTooLarge
      }
      bytes.write_bytes(chunk)
    }
  })
  bytes.to_bytes()
}

///|
fn artifact_block_list(text : String) -> Array[String] raise {
  guard !text.contains("<!") && !text.contains("&") else {
    raise @domain.BadRequest(message="invalid block list XML")
  }
  let mut content = text.trim().to_owned()
  if content.has_prefix("<?xml ") {
    guard content.split_once("?>") is Some((_, tail)) else {
      raise @domain.BadRequest(message="invalid block list XML")
    }
    content = tail.trim().to_owned()
  }
  guard content.strip_prefix("<BlockList>") is Some(body) &&
    body.strip_suffix("</BlockList>") is Some(body) else {
    raise @domain.BadRequest(message="invalid block list XML")
  }
  let result : Array[String] = []
  let mut rest = body.trim().to_owned()
  while !rest.is_empty() {
    guard rest.strip_prefix("<Latest>") is Some(tail) &&
      tail.split_once("</Latest>") is Some((value, after)) &&
      !value.is_empty() &&
      value.length() <= 128 &&
      value
      .iter()
      .all(ch => {
        ch.is_ascii_alphabetic() ||
        ch.is_ascii_digit() ||
        ['+', '/', '='].contains(ch)
      }) else {
      raise @domain.BadRequest(message="invalid block list XML")
    }
    result.push(value.to_owned())
    guard result.length() <= 64 else {
      raise @domain.BadRequest(message="artifact block count exceeded")
    }
    rest = after.trim().to_owned()
  }
  result
}

///|
// Release scarce transfer slots on errors/cancellation, and reject authorization
// that expired while queued before the caller opens files or sends headers.
async fn[T] with_artifact_transfer(
  transfers : @async.Semaphore,
  authorize : () -> Unit raise,
  f : async () -> T,
  timeout_ms~ : Int32 = 30000,
) -> T {
  @async.with_timeout(timeout_ms, () => transfers.acquire())
  defer transfers.release()
  authorize()
  f()
}

///|
async fn stream_artifact(
  file : @fs.File,
  writer : &@io.Writer,
  authorize : () -> Unit raise,
  timeout_ms~ : Int32 = 30000,
) -> Unit {
  while file.read_some(max_len=65536) is Some(chunk) {
    authorize()
    @async.with_timeout(timeout_ms, () => writer.write(chunk))
  }
}

///|
pub let artifact_blob_module : @moonback.Module = Module(ctx => {
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  let root = ctx.require(@web_context.config_root)
  // Bound in-flight upload buffers, disk staging and download file descriptors.
  let transfers = @async.Semaphore(4)
  ctx.add_route(@http.Put, "/:id", async fn(req, res) {
    try {
      let id = @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "artifact"),
      )
      let sig = req.query().get("sig").unwrap_or("")
      coordinator.authorize_artifact_blob(id, sig, "write")
      with_artifact_transfer(
        transfers,
        () => coordinator.authorize_artifact_blob(id, sig, "write"),
        () => {
          match req.query().get("comp") {
            Some("block") => {
              let block = req.query().get("blockid").unwrap_or("")
              let bytes = artifact_request_bytes(
                req, @pipeline.maximum_artifact_block_bytes,
              )
              coordinator.stage_artifact_block(root, id, sig, block, bytes)
            }
            Some("blocklist") => {
              let text = @utf8.decode(artifact_request_bytes(req, 65536))
              coordinator.commit_artifact_blocks(
                root,
                id,
                sig,
                artifact_block_list(text),
              )
            }
            _ => raise @domain.BadRequest(message="unsupported blob operation")
          }
          let writer = @async.with_timeout(30000, () => {
            res.respond(status=201, headers={
              "Content-Length": "0",
              "ETag": "\"moonhub-artifact\"",
              "x-ms-request-id": @identity.random_hex(16),
              "x-ms-version": "2023-11-03",
              "Cache-Control": "no-store",
            })
          })
          writer.write("")
        },
      )
    } catch {
      err => {
        let (status, json) = artifact_error(err)
        res.send_json(json, status~, headers={
          "Cache-Control": "no-store",
          "Connection": "close",
        })
      }
    }
  })
  ctx.get("/:id", async fn(req, res) {
    let blob = try {
      let id = @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "artifact"),
      )
      coordinator.artifact_blob(root, id, req.query().get("sig").unwrap_or(""))
    } catch {
      err => {
        let (status, json) = artifact_error(err)
        res.send_json(json, status~, headers={
          "Cache-Control": "no-store",
          "Connection": "close",
        })
        return
      }
    }
    let authorize = () => {
      coordinator.authorize_artifact_blob(
        blob.id,
        req.query().get("sig").unwrap_or(""),
        "read",
      )
    }
    with_artifact_transfer(transfers, authorize, () => {
      let file = @fs.open(blob.path, mode=ReadOnly)
      defer file.close()
      guard file.size() == blob.size else {
        raise @domain.NotFound(message="artifact data missing")
      }
      let writer = @async.with_timeout(30000, () => {
        res.respond(status=200, headers={
          "Content-Type": "application/zip",
          "Content-Length": blob.size.to_string(),
          "Cache-Control": "private, no-store",
          "X-Content-Type-Options": "nosniff",
          "Content-Disposition": "attachment; filename=artifact.zip",
        })
      })
      stream_artifact(file, writer, authorize)
    })
  })
})
