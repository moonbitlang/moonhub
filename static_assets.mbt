///|
fn asset_request_relative_path(path : StringView) -> String? {
  let raw = path.to_owned()
  let path = if raw.has_prefix("/") { raw } else { "/\{raw}" }
  guard !path.contains("\\") else { return None }
  let segments = []
  for segment in path.split("/").collect() {
    match segment {
      "" | "." => ()
      ".." => return None
      segment => segments.push(segment.to_owned())
    }
  }
  guard !segments.is_empty() else { return None }
  Some(segments.join("/"))
}

///|
fn asset_join_path(root : String, relative : String) -> String {
  guard root != "" else { return relative }
  if root.has_suffix("/") {
    root + relative
  } else {
    "\{root}/\{relative}"
  }
}

///|
fn asset_content_type(path : String) -> String {
  match path.to_lower() {
    [.., .. ".html"] => "text/html; charset=utf-8"
    [.., .. ".css"] => "text/css; charset=utf-8"
    [.., .. ".js"] => "text/javascript; charset=utf-8"
    [.., .. ".mjs"] => "text/javascript; charset=utf-8"
    [.., .. ".json"] => "application/json; charset=utf-8"
    [.., .. ".txt"] => "text/plain; charset=utf-8"
    [.., .. ".svg"] => "image/svg+xml"
    [.., .. ".png"] => "image/png"
    [.., .. ".jpg"] | [.., .. ".jpeg"] => "image/jpeg"
    [.., .. ".gif"] => "image/gif"
    [.., .. ".ico"] => "image/x-icon"
    [.., .. ".wasm"] => "application/wasm"
    [.., .. ".pdf"] => "application/pdf"
    _ => "application/octet-stream"
  }
}

///|
fn asset_cache_control(relative_path : String) -> String {
  let _ = relative_path
  "public, max-age=31536000, immutable"
}

///|
fn asset_public_path(relative_path : String) -> Bool {
  for segment in relative_path.split("/") {
    if segment.has_prefix(".") {
      return false
    }
  }
  true
}

///|
async fn asset_regular_file(path : String) -> Bool {
  try @fs.kind(path) catch {
    _ => false
  } noraise {
    kind => kind is Regular
  }
}

///|
async fn send_static_asset(
  req : @moonback.Request,
  res : @moonback.Responder,
  file_path : String,
  relative_path : String,
  on_missing : @moonback.Handler,
) -> Unit {
  try {
    let file = @fs.open(file_path, mode=ReadOnly)
    defer file.close()
    if req.meth is Head {
      let headers = @moonback.Headers::from([
        ("Content-Type", asset_content_type(file_path)),
        ("Cache-Control", asset_cache_control(relative_path)),
      ])
      res.send_void(status=200, headers~)
    } else {
      let size = file.size()
      let headers = @moonback.Headers::from([
        ("Content-Type", asset_content_type(file_path)),
        ("Content-Length", size.to_string()),
        ("Cache-Control", asset_cache_control(relative_path)),
      ])
      let writer = res.respond(status=200, headers~)
      writer.write_reader(file) catch {
        _ => ()
      }
    }
  } catch {
    @os_error.OSError(_) as err if err.is_ENOENT() => on_missing(req, res)
    @os_error.OSError(_) as err if err.is_EACCES() => res.send_void(status=403)
    _ => res.send_void(status=500)
  }
}

///|
fn static_assets(root~ : String) -> @moonback.Middleware {
  Middleware(next => {
    (req, res) => {
      guard req.meth is Get || req.meth is Head else {
        next(req, res)
        return
      }
      guard asset_request_relative_path(req.path) is Some(relative_path) else {
        res.send_void(status=404)
        return
      }
      guard asset_public_path(relative_path) else {
        res.send_void(status=404)
        return
      }
      let file_path = asset_join_path(root, relative_path)
      if asset_regular_file(file_path) {
        send_static_asset(req, res, file_path, relative_path, next)
      } else {
        next(req, res)
      }
    }
  })
}
