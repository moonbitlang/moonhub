///|
// Uploads and garbage collection share a volume lock. A cascade may delete
// metadata during an upload, but cleanup cannot finish before its final write.
async fn attachment_storage_lock(root : String) -> @fs.File {
  let root = @domain.trim_trailing_slash(@fs.realpath(root))
  let directory = "\{root}/.attachments"
  @fs.mkdir(directory, recursive=true, permission=0o700) catch {
    err => if !@fs.exists(directory) { raise err }
  }
  guard @fs.realpath(directory) == directory else {
    raise @domain.BadRequest(message="invalid attachment storage directory")
  }
  let path = "\{directory}/storage.lock"
  let kind = Some(@fs.kind(path, follow_symlink=false)) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() => None
    err => raise err
  }
  guard kind is (None | Some(Regular)) else {
    raise @domain.BadRequest(message="invalid attachment storage lock")
  }
  @fs.open(path, mode=ReadWrite, create_mode=OpenOrCreate, permission=0o600)
}

///|
async fn cleanup_attachment_garbage(
  pool : @database.Database,
  root : String,
) -> Unit {
  let rows = pool.with_client(client => {
    client.query_all(
      "SELECT id FROM attachment_file_garbage WHERE next_attempt_at<=datetime('now') LIMIT 100",
    )
  })
  for row in rows {
    let id : String = row.get_name("id")
    try {
      guard valid_id(id) else {
        raise @domain.BadRequest(message="invalid attachment cleanup ID")
      }
      for suffix in ["", ".tmp"] {
        let path = storage_path(root, id) + suffix
        let kind = Some(@fs.kind(path, follow_symlink=false)) catch {
          @os_error.OSError(_) as err if err.is_ENOENT() => None
          err => raise err
        }
        if kind is Some(kind) {
          guard kind is Regular else {
            raise @domain.BadRequest(
              message="invalid attachment cleanup target",
            )
          }
          @fs.remove(path)
        }
      }
      pool.with_client(client => {
        ignore(
          client.execute("DELETE FROM attachment_file_garbage WHERE id=?", params=[
            id,
          ]),
        )
      })
    } catch {
      err if @async.is_being_cancelled() => raise err
      err => {
        let message = match err {
          @domain.BadRequest(message~) => message
          _ => "\{err}"
        }
        println("attachment cleanup failed for \{id}: \{message}")
        pool.with_client(client => {
          ignore(
            client.execute(
              "UPDATE attachment_file_garbage SET attempts=attempts+1,last_error=?,next_attempt_at=datetime('now','+1 minute') WHERE id=?",
              params=[message, id],
            ),
          )
        })
      }
    }
  }
}
