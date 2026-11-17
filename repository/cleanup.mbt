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
  guard @gitops.try_file_lock("\{work}/worker.lock") is Some(lock) else {
    return
  }
  defer lock.close()
  let rows = pool.with_client(client => {
    client.query_all(
      "SELECT * FROM repository_file_garbage WHERE next_attempt_at<=datetime('now') ORDER BY next_attempt_at,id LIMIT 100",
    )
  })
  for row in rows {
    let id : Int64 = row.get_name("id")
    try {
      let owner : String = row.get_name("owner")
      let name : String = row.get_name("name")
      let repo = @domain.parse_transport_repo("\{owner}/\{name}.git")
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
      let path = if kind == "git" {
        repository_lock_path(root, repo)
      } else {
        mirror_lock_path(root, resource_id)
      }
      guard @gitops.try_file_lock(path) is Some(writer) else {
        defer_busy_cleanup(pool, id)
        continue
      }
      defer writer.close()
      let readers = if kind == "git" {
        guard @gitops.try_file_lock(
            repository_reader_lock_path(root, repository_id),
          )
          is Some(readers) else {
          defer_busy_cleanup(pool, id)
          continue
        }
        Some(readers)
      } else {
        None
      }
      defer (if readers is Some(readers) { readers.close() })
      // Recheck the journal and ownership only after holding both lifetime locks.
      guard pool.with_client(client => {
        client.query_opt(
          "SELECT id FROM repository_file_garbage WHERE id=? AND repository_id=? AND resource_id=? AND kind=? AND path=? AND owner=? AND name=?",
          params=[id, repository_id, resource_id, kind, relative, owner, name],
        )
        is Some(_)
      }) else {
        continue
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
// Contention is not a failed attempt. Move busy work behind older due tasks,
// including tasks beyond the current batch, without changing failure history.
fn defer_busy_cleanup(pool : @database.Database, id : Int64) -> Unit raise {
  pool.with_client(client => {
    ignore(
      client.execute(
        "UPDATE repository_file_garbage SET next_attempt_at=datetime('now','+1 second') WHERE id=?",
        params=[id],
      ),
    )
  })
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
