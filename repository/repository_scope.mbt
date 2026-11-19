///|
pub(all) struct RepositoryScope {
  id : Int64
  repo : @domain.RepoId
  team_id : Int64
}

///|
pub fn repository_scope(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> RepositoryScope raise {
  readable_repository_scope(pool, Some(actor), repo)
}

///|
pub fn readable_repository_scope(
  pool : @database.Database,
  actor : @domain.CurrentUser?,
  repo : @domain.RepoId,
) -> RepositoryScope raise {
  guard try_readable_repository_scope(pool, actor, repo) is Some(scope) else {
    raise @domain.NotFound(message="repository not found or access denied")
  }
  scope
}

///|
// Compare the original identity after any wait, before resolving data paths.
pub fn require_current_scope(
  pool : @database.Database,
  expected : RepositoryScope,
) -> Unit raise {
  pool.with_client(client => {
    guard client.query_opt(
        "SELECT r.id,r.team_id,r.name,t.name_key AS owner FROM repository r JOIN team t ON t.id=r.team_id WHERE r.ready=1 AND (r.id=? OR (t.name_key=? AND r.name=?)) ORDER BY (r.id=?) DESC LIMIT 1",
        params=[
          expected.id,
          expected.repo.owner,
          expected.repo.name,
          expected.id,
        ],
      )
      is Some(row) else {
      raise @domain.NotFound(message="repository not found")
    }
    guard (row.get_name("id") : Int64) == expected.id &&
      (row.get_name("team_id") : Int64) == expected.team_id &&
      (row.get_name("owner") : String) == expected.repo.owner &&
      (row.get_name("name") : String) == expected.repo.name else {
      raise @domain.BadRequest(
        message="repository has changed; reload its settings",
      )
    }
  })
}

///|
// Validate a captured repository identity inside the caller's database
// transaction so path reuse cannot redirect an in-flight mutation.
pub fn require_current_scope_tx(
  tx : @database.DbTransaction,
  expected : RepositoryScope,
) -> Unit raise {
  guard tx.query_opt(
      "SELECT r.id,r.team_id,r.name,t.name_key AS owner FROM repository r JOIN team t ON t.id=r.team_id WHERE r.id=? AND r.ready=1",
      params=[expected.id],
    )
    is Some(row) else {
    raise @domain.NotFound(message="repository not found")
  }
  guard (row.get_name("team_id") : Int64) == expected.team_id &&
    (row.get_name("owner") : String) == expected.repo.owner &&
    (row.get_name("name") : String) == expected.repo.name else {
    raise @domain.NotFound(message="repository has changed")
  }
}

///|
/// Admit a Git reader without holding the name lock for the duration of the read.
/// The caller must close the returned lifetime lock after the last Git operation.
pub async fn open_repository_read(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser?,
  scope : RepositoryScope,
) -> (@fs.File, String) {
  let admission = repository_read_lock(root, scope.repo)
  defer admission.close()
  let current = readable_repository_scope(pool, actor, scope.repo)
  guard current.id == scope.id && current.team_id == scope.team_id else {
    raise @domain.NotFound(message="repository has changed")
  }
  let dir = resolve_repository_dir(root, scope.repo)
  (repository_reader_lock(root, scope.id), dir)
}

///|
pub async fn[A] with_repository_write(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  scope : RepositoryScope,
  f : async (RepositoryScope, String) -> A,
) -> A {
  authorize_repository(pool, actor, scope.repo, Write)
  let lock = repository_write_lock(root, scope.repo)
  defer lock.close()
  authorize_repository(pool, actor, scope.repo, Write)
  require_current_scope(pool, scope)
  let git_dir = resolve_repository_dir(root, scope.repo)
  recover_ref_events_locked(pool, scope, git_dir)
  f(scope, git_dir)
}
