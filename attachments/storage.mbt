///|
pub let maximum_image_bytes : Int32 = 5242880

///|
pub let maximum_body_bytes : Int32 = 16777216

///|
pub struct Image {
  id : String
  url : String
  media_type : String
  byte_size : Int64
}

///|
fn image_type(bytes : Bytes) -> String raise {
  if bytes.length() >= 24 &&
    bytes[:8] == b"\x89PNG\r\n\x1a\n" &&
    bytes[12:16] == b"IHDR" {
    "image/png"
  } else if bytes.length() >= 4 &&
    bytes[:3] == b"\xff\xd8\xff" &&
    bytes[bytes.length() - 2:] == b"\xff\xd9" {
    "image/jpeg"
  } else if bytes.length() >= 13 &&
    (bytes[:6] == b"GIF87a" || bytes[:6] == b"GIF89a") {
    "image/gif"
  } else if bytes.length() >= 16 &&
    bytes[:4] == b"RIFF" &&
    bytes[8:12] == b"WEBP" &&
    (
      bytes[12:16] == b"VP8 " ||
      bytes[12:16] == b"VP8L" ||
      bytes[12:16] == b"VP8X"
    ) {
    "image/webp"
  } else {
    raise @domain.BadRequest(
      message="only PNG, JPEG, GIF and WebP images are supported",
    )
  }
}

///|
fn storage_path(root : String, id : String) -> String {
  "\{root}/.attachments/\{id}"
}

///|
pub async fn upload(
  pool : @database.Database,
  root : String,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  filename : String,
  bytes : Bytes,
) -> Image {
  @repository.authorize_repository(pool, actor, scope.repo, Write)
  guard !bytes.is_empty() && bytes.length() <= maximum_image_bytes else {
    raise @domain.BadRequest(
      message="each image must be between 1 byte and 5 MiB",
    )
  }
  guard filename.length() <= 200 &&
    !filename.iter().any(c => c.to_int() < 32 || c.to_int() == 127) else {
    raise @domain.BadRequest(message="invalid image filename")
  }
  let media_type = image_type(bytes)
  let id = @identity.random_hex(32)
  let digest = @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
  let byte_size = bytes.length().to_int64()
  @fs.mkdir("\{root}/.attachments", recursive=true, permission=0o700) catch {
    err => if !@fs.exists("\{root}/.attachments") { raise err }
  }
  // Reserve metadata first so a process crash leaves an expirable upload.
  pool.with_client(client => {
    ignore(
      client.execute(
        "INSERT INTO attachment(id, repository_id, uploader_id, filename, media_type, byte_size, sha256) VALUES (?, ?, ?, ?, ?, ?, ?)",
        params=[id, scope.id, actor.id, filename, media_type, byte_size, digest],
      ),
    )
  })
  let path = storage_path(root, id)
  errdefer {
    @fs.remove(path) catch {
      _ => ()
    }
    @fs.remove(path + ".tmp") catch {
      _ => ()
    }
    pool.with_client(client => {
      ignore(
        client.execute("DELETE FROM attachment WHERE id = ? AND ready = 0", params=[
          id,
        ]),
      )
    }) catch {
      _ => ()
    }
  }
  @fs.write_file(
    path + ".tmp",
    bytes,
    create_mode=CreateNew,
    permission=0o600,
    sync=Full,
  )
  @fs.rename(path + ".tmp", path, replace=false)
  @repository.authorize_repository(pool, actor, scope.repo, Write)
  pool.with_client(client => {
    ignore(
      client.execute("UPDATE attachment SET ready = 1 WHERE id = ?", params=[id]),
    )
  })
  { id, url: url(scope.repo, id), media_type, byte_size, }
}

///|
pub async fn read(
  pool : @database.Database,
  root : String,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  id : String,
) -> (String, Bytes) {
  @repository.authorize_repository(pool, actor, scope.repo, Read)
  guard valid_id(id) else { raise @domain.NotFound(message="image not found") }
  let media_type : String = pool.with_client(client => {
    guard client.query_opt(
        "SELECT media_type FROM attachment a WHERE id = ? AND repository_id = ? AND ready = 1 AND (uploader_id = ? OR EXISTS (SELECT 1 FROM attachment_reference r WHERE r.attachment_id = a.id))",
        params=[id, scope.id, actor.id],
      )
      is Some(row) else {
      raise @domain.NotFound(message="image not found")
    }
    row.get_name("media_type")
  })
  let bytes = @fs.read_file(storage_path(root, id)).binary() catch {
    _ => raise @domain.NotFound(message="image not found")
  }
  (media_type, bytes)
}

///|
// Uploads are pending until referenced by a committed description or comment.
// Claim expiry before awaiting filesystem IO so linking and expiry cannot race.
// Previously linked images are retained through edits and soft deletes.
pub async fn cleanup_pending(pool : @database.Database, root : String) -> Unit {
  let ids : Array[String] = pool.with_client(client => {
    client
    .query_all(
      "UPDATE attachment SET ready = 2 WHERE id IN (SELECT a.id FROM attachment a WHERE a.claimed = 0 AND (a.ready = 2 OR a.created_at < datetime('now', '-1 day')) AND NOT EXISTS (SELECT 1 FROM attachment_reference r WHERE r.attachment_id = a.id) LIMIT 100) RETURNING id",
    )
    .map(row => row.get_name("id"))
  })
  for id in ids {
    let path = storage_path(root, id)
    if @fs.exists(path) {
      @fs.remove(path)
    }
    if @fs.exists(path + ".tmp") {
      @fs.remove(path + ".tmp")
    }
    pool.with_client(client => {
      ignore(
        client.execute(
          "DELETE FROM attachment WHERE id = ? AND ready = 2 AND claimed = 0",
          params=[id],
        ),
      )
    })
  }
}

///|
pub fn start_cleanup_worker(
  pool : @database.Database,
  root : String,
  group : @async.TaskGroup[Unit],
) -> Unit {
  group.spawn_bg(no_wait=true, () => {
    for ;; {
      cleanup_pending(pool, root) catch {
        err if @async.is_cancellation_error(err) => raise err
        _ => println("attachment cleanup failed; retrying later")
      }
      @async.sleep(3600000)
    }
  })
}

///|
pub async fn prepare_markdown(
  pool : @database.Database,
  root : String,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  markdown : String,
) -> String {
  guard markdown.length() <= maximum_body_bytes else {
    raise @domain.BadRequest(message="image-inclusive Markdown is too large")
  }
  let links = image_links(markdown)
  let inline_images = links.filter(image => image.url.has_prefix("data:"))
  guard inline_images.length() <= 8 else {
    raise @domain.BadRequest(
      message="at most 8 inline images are allowed per body",
    )
  }
  let decoded : Array[(ImageLink, Bytes)] = []
  let mut total_bytes = 0
  // Validate every image and the final text bound before writing any files.
  let mut final_length = markdown.length()
  for image in inline_images {
    guard image.url.find(";base64,") is Some(separator) else {
      raise @domain.BadRequest(
        message="inline images must use base64 data URIs",
      )
    }
    let declared = image.url[5:separator].to_owned()
    guard ["image/png", "image/jpeg", "image/gif", "image/webp"].contains(
      declared,
    ) else {
      raise @domain.BadRequest(message="unsupported inline image type")
    }
    let bytes = @base64.decode(image.url[separator + 8:]) catch {
      _ => raise @domain.BadRequest(message="invalid inline image base64")
    }
    guard bytes.length() <= maximum_image_bytes && image_type(bytes) == declared else {
      raise @domain.BadRequest(message="inline image type or size is invalid")
    }
    total_bytes = total_bytes + bytes.length()
    guard total_bytes <= 10485760 else {
      raise @domain.BadRequest(
        message="inline images must total at most 10 MiB",
      )
    }
    final_length = final_length -
      image.url.length() +
      url(scope.repo, "".pad_start(64, '0')).length()
    decoded.push((image, bytes))
  }
  guard final_length <= 20000 else {
    raise @domain.BadRequest(
      message="Markdown must contain at most 20000 characters after image upload",
    )
  }
  let out = StringBuilder()
  let mut position = 0
  for (image, bytes) in decoded {
    let uploaded = upload(pool, root, scope, actor, "inline-image", bytes)
    out.write_string(markdown[position:image.start].to_owned())
    out.write_string(uploaded.url)
    position = image.end
  }
  out.write_string(markdown[position:].to_owned())
  out.to_string()
}
