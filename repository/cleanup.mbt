///|
async fn cleanup_kind(path : String) -> @fs.FileKind? {
  Some(@fs.kind(path, follow_symlink=false)) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() => None
    err => raise err
  }
}

///|
async fn remove_cleanup_tree(path : String) -> Unit {
  try {
    match cleanup_kind(path) {
      None => ()
      Some(Regular) => @fs.remove(path)
      Some(Directory) => {
        for name in @fs.readdir(path, include_hidden=true) {
          remove_cleanup_tree(path + "/" + name)
        }
        @fs.rmdir(path)
      }
      _ =>
        raise @domain.BadRequest(
          message="cleanup refuses symbolic links and special files",
        )
    }
  } catch {
    // Artifact orphan collection may remove the same files concurrently.
    @os_error.OSError(_) as err if err.is_ENOENT() => ()
    err => raise err
  }
}

///|
/// Remove one manifest-owned path under the shared storage root. Missing paths
/// are successful retries; every ancestor and descendant must be a real path.
pub async fn remove_cleanup_path(root : String, relative : String) -> Unit {
  let components = relative.split("/").to_array()
  guard !components.is_empty() &&
    components
    .iter()
    .all(part => {
      !part.is_empty() &&
      part != "." &&
      part != ".." &&
      !part.contains("\\") &&
      !part.contains("\u0000")
    }) else {
    raise @domain.BadRequest(message="invalid cleanup path")
  }
  let mut path = @domain.trim_trailing_slash(@fs.realpath(root))
  for i in 0..<components.length() {
    path += "/" + components[i].to_owned()
    match cleanup_kind(path) {
      None => return
      Some(Directory) => ()
      Some(Regular) if i == components.length() - 1 => ()
      _ =>
        raise @domain.BadRequest(
          message="cleanup path contains a symbolic link or special file",
        )
    }
  }
  remove_cleanup_tree(path)
}

///|
fn deletion_resources(
  pool : @database.Database,
  id : Int64,
  kind : String,
) -> Array[String] raise {
  pool.with_client(client => {
    client
    .query_all(
      "SELECT resource FROM repository_deletion_resource WHERE repository_id=? AND kind=? ORDER BY resource",
      params=[id, kind],
    )
    .map(row => row.get_name("resource"))
  })
}

///|
pub async fn run_next_repository_deletion(
  pool : @database.Database,
  root : String,
  cleanup_attachments~ : async (Array[String]) -> Unit,
  cleanup_artifacts~ : async (Array[String]) -> Unit,
) -> Bool {
  guard pool.with_client(client => {
      client.query_opt(
        "SELECT repository_id FROM repository_deletion WHERE next_attempt_at<=datetime('now') LIMIT 1",
      )
    })
    is Some(_) else {
    return false
  }
  let root = @domain.trim_trailing_slash(@fs.realpath(root))
  let work = root + "/.repository-cleanup"
  if cleanup_kind(work) is None {
    @fs.mkdir(work, permission=0o700) catch {
      err => if cleanup_kind(work) is None { raise err }
    }
  }
  guard cleanup_kind(work) is Some(Directory) else {
    raise @domain.BadRequest(message="invalid repository cleanup directory")
  }
  let path = work + "/worker.lock"
  guard cleanup_kind(path) is (None | Some(Regular)) else {
    raise @domain.BadRequest(message="invalid repository cleanup lock")
  }
  let lock = @fs.open(
    path,
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  guard lock.try_lock(Exclusive) else { return false }
  let row = pool.with_client(client => {
    client.query_opt(
      "SELECT * FROM repository_deletion WHERE next_attempt_at<=datetime('now') ORDER BY repository_id LIMIT 1",
    )
  })
  guard row is Some(row) else { return false }
  let id : Int64 = row.get_name("repository_id")
  try {
    let owner : String = row.get_name("owner")
    let name : String = row.get_name("name")
    let repo = @domain.parse_transport_repo("\{owner}/\{name}.git")
    guard repo.owner == owner && repo.name == name else {
      raise @domain.BadRequest(message="invalid repository cleanup identity")
    }
    cleanup_attachments(deletion_resources(pool, id, "attachment"))
    cleanup_artifacts(deletion_resources(pool, id, "artifact"))
    for mirror in deletion_resources(pool, id, "mirror") {
      let mirror_id = @string.parse_int64(mirror) catch {
        _ => raise @domain.BadRequest(message="invalid mirror cleanup identity")
      }
      guard mirror_id > 0 && mirror_id.to_string() == mirror else {
        raise @domain.BadRequest(message="invalid mirror cleanup identity")
      }
      remove_cleanup_path(root, ".mirrors/" + mirror)
    }
    remove_cleanup_path(root, "\{repo.owner}/\{repo.name}.git")
    pool.with_client(client => {
      ignore(
        client.execute(
          "DELETE FROM repository_deletion WHERE repository_id=?",
          params=[id],
        ),
      )
    })
  } catch {
    err if @async.is_being_cancelled() => {
      @async.pause()
      raise err
    }
    _ =>
      pool.with_client(client => {
        ignore(
          client.execute(
            "UPDATE repository_deletion SET attempts=attempts+1,last_error='Storage cleanup failed; will retry',next_attempt_at=datetime('now','+30 seconds') WHERE repository_id=?",
            params=[id],
          ),
        )
      })
  }
  true
}

///|
pub fn start_repository_deletion_worker(
  pool : @database.Database,
  root : String,
  group : @async.TaskGroup[Unit],
  cleanup_attachments~ : async (Array[String]) -> Unit,
  cleanup_artifacts~ : async (Array[String]) -> Unit,
) -> Unit {
  group.spawn_bg(no_wait=true, () => {
    for ;; {
      let processed = run_next_repository_deletion(
        pool,
        root,
        cleanup_attachments~,
        cleanup_artifacts~,
      ) catch {
        _ => {
          println("repository cleanup failed; will retry")
          false
        }
      }
      if !processed {
        @async.sleep(1000)
      }
    }
  })
}
