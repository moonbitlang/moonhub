///|
pub async fn cleanup_deleted_repositories(
  pool : @database.Database,
  root : String,
) -> Unit {
  let root = @domain.trim_trailing_slash(@fs.realpath(root))
  let work = "\{root}/.repository-cleanup"
  @fs.mkdir(work, recursive=true, permission=0o700) catch {
    err => if !@fs.exists(work) { raise err }
  }
  guard @fs.realpath(work) == work else {
    raise @domain.BadRequest(message="invalid repository cleanup directory")
  }
  let lock_path = "\{work}/worker.lock"
  let lock_kind = Some(@fs.kind(lock_path, follow_symlink=false)) catch {
    @os_error.OSError(_) as err if err.is_ENOENT() => None
    err => raise err
  }
  guard lock_kind is (None | Some(Regular)) else {
    raise @domain.BadRequest(message="invalid repository cleanup lock")
  }
  let lock = @fs.open(
    lock_path,
    mode=ReadWrite,
    create_mode=OpenOrCreate,
    permission=0o600,
  )
  defer lock.close()
  guard lock.try_lock(Exclusive) else { return }
  let rows = pool.with_client(client => {
    client.query_all(
      "SELECT * FROM repository_file_garbage WHERE next_attempt_at<=datetime('now') ORDER BY id LIMIT 100",
    )
  })
  for row in rows {
    let id : Int64 = row.get_name("id")
    try {
      let owner : String = row.get_name("owner")
      let name : String = row.get_name("name")
      let repo = @domain.parse_transport_repo("\{owner}/\{name}")
      let repository_id : Int64 = row.get_name("repository_id")
      let resource_id : Int64 = row.get_name("resource_id")
      let kind : String = row.get_name("kind")
      let relative : String = row.get_name("path")
      let expected = match kind {
        "git" if resource_id == repository_id => "\{repo.path()}.git"
        "mirror" if resource_id > 0L => ".mirrors/\{resource_id}"
        _ => raise @domain.BadRequest(message="invalid repository cleanup kind")
      }
      guard relative == expected && repo.owner == owner && repo.name == name else {
        raise @domain.BadRequest(message="invalid repository cleanup path")
      }
      let registered = pool.with_client(client => {
        if kind == "git" {
          client.query_opt(
            "SELECT r.id FROM repository r JOIN team t ON t.id=r.team_id WHERE r.id=? OR (t.name_key=? AND r.name=?) LIMIT 1",
            params=[repository_id, owner, name],
          )
        } else {
          client.query_opt(
            "SELECT id FROM repository WHERE id=? UNION ALL SELECT repository_id AS id FROM repository_mirror WHERE id=? LIMIT 1",
            params=[repository_id, resource_id],
          )
        }
      })
      // Mirror directories are globally unique IDs and can be cleaned after a rebuild.
      guard registered is None else {
        raise @domain.BadRequest(
          message="cleanup path belongs to a registered repository",
        )
      }
      let parent = if kind == "git" {
        "\{root}/\{owner}"
      } else {
        "\{root}/.mirrors"
      }
      let parent_kind = Some(@fs.kind(parent, follow_symlink=false)) catch {
        @os_error.OSError(_) as err if err.is_ENOENT() => None
        err => raise err
      }
      guard parent_kind is (None | Some(Directory)) else {
        raise @domain.BadRequest(message="invalid repository cleanup parent")
      }
      if parent_kind is Some(_) {
        guard @fs.realpath(parent) == parent else {
          raise @domain.BadRequest(message="invalid repository cleanup parent")
        }
      }
      let path = "\{root}/\{relative}"
      let target_kind = Some(@fs.kind(path, follow_symlink=false)) catch {
        @os_error.OSError(_) as err if err.is_ENOENT() => None
        err => raise err
      }
      if target_kind is Some(kind) {
        guard kind is Directory && @fs.realpath(path) == path else {
          raise @domain.BadRequest(message="invalid repository cleanup target")
        }
        // Existing pushes/merges and mirror configuration writes use this lock too.
        let writer = @gitops.repository_write_lock(path)
        defer writer.close()
        @fs.rmdir(path, recursive=true)
      }
      pool.with_client(client => {
        ignore(
          client.execute("DELETE FROM repository_file_garbage WHERE id=?", params=[
            id,
          ]),
        )
      })
    } catch {
      err if @async.is_being_cancelled() => raise err
      err => {
        let message = match err {
          @domain.BadRequest(message~) | @gitops.Failure(message~) => message
          _ => "\{err}"
        }
        println("repository cleanup task \{id} failed: \{message}")
        pool.with_client(client => {
          ignore(
            client.execute(
              "UPDATE repository_file_garbage SET attempts=attempts+1,last_error=?,next_attempt_at=datetime('now','+1 minute') WHERE id=?",
              params=[message, id],
            ),
          )
        })
      }
    }
  }
}

///|
pub fn start_repository_cleanup_worker(
  pool : @database.Database,
  root : String,
  group : @async.TaskGroup[Unit],
) -> Unit {
  group.spawn_bg(no_wait=true, () => {
    for ;; {
      cleanup_deleted_repositories(pool, root) catch {
        err => println("repository cleanup worker failed: \{err}")
      }
      @async.sleep(1000)
    }
  })
}
