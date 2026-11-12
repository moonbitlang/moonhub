///|
fn require_repository_name_available(
  pool : @database.Database,
  repo : @domain.RepoId,
) -> Unit raise {
  pool.with_client(client => {
    guard client.query_opt(
        "SELECT repository_id FROM repository_deletion WHERE owner=? AND name=?",
        params=[repo.owner, repo.name],
      )
      is None else {
      raise @domain.BadRequest(
        message="repository cleanup is pending; retry after cleanup completes",
      )
    }
  })
}

///|
/// Permanently remove a ready repository. The immutable ID protects callers
/// holding an old form or request from deleting a replacement at the same path.
pub async fn delete_repository(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  expected_id : Int64,
  confirmation : String,
) -> Unit {
  let scope = require_repository_admin(pool, actor, repo)
  guard scope.id == expected_id else {
    raise @domain.BadRequest(
      message="repository identity changed; reload the settings page",
    )
  }
  guard confirmation == repo.path() else {
    raise @domain.BadRequest(
      message="enter the full repository name exactly: \{repo.path()}",
    )
  }
  let git_dir = resolve_repository_dir(root, repo)
  let lock = @gitops.repository_write_lock(git_dir) catch {
    @gitops.Failure(message~) => raise @domain.BadRequest(message~)
    err => raise err
  }
  defer lock.close()
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        let current = require_repository_admin(pool, actor, repo)
        guard current.id == expected_id else {
          raise @domain.BadRequest(
            message="repository identity changed; reload the settings page",
          )
        }
        guard tx.query_opt(
            "SELECT id FROM pipeline_run WHERE repository_id=? AND status<>'completed' UNION ALL SELECT j.id FROM pipeline_job j JOIN pipeline_run r ON r.id=j.run_id WHERE r.repository_id=? AND j.status<>'completed' UNION ALL SELECT a.id FROM pipeline_job_attempt a JOIN pipeline_job j ON j.id=a.job_id JOIN pipeline_run r ON r.id=j.run_id WHERE r.repository_id=? AND a.status<>'completed' LIMIT 1",
            params=[scope.id, scope.id, scope.id],
          )
          is None else {
          raise @domain.BadRequest(
            message="CI tasks are still active; cancel them or wait for completion before deleting",
          )
        }
        guard tx.query_opt(
            "SELECT id FROM repository_mirror WHERE repository_id=? AND status='syncing' LIMIT 1",
            params=[scope.id],
          )
          is None else {
          raise @domain.BadRequest(
            message="a mirror is syncing; wait for completion before deleting",
          )
        }
        ignore(
          tx.execute(
            "INSERT INTO repository_deletion(repository_id,owner,name) VALUES(?,?,?)",
            params=[scope.id, repo.owner, repo.name],
          ),
        )
        for
          (kind, table, column) in [
            ("attachment", "attachment", "id"),
            ("artifact", "pipeline_artifact", "storage_key"),
            ("mirror", "repository_mirror", "id"),
          ] {
          ignore(
            tx.execute(
              "INSERT INTO repository_deletion_resource(repository_id,kind,resource) SELECT repository_id,?,CAST(\{column} AS TEXT) FROM \{table} WHERE repository_id=?",
              params=[kind, scope.id],
            ),
          )
        }
        // FK cascades remove business data and delivery retries. The existing
        // deploy-key trigger keeps revoked credential tombstones.
        ignore(
          tx.execute("DELETE FROM repository WHERE id=?", params=[scope.id]),
        )
      },
      immediate=true,
    )
  })
}
