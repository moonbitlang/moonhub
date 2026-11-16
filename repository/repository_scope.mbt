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
  authorize_repository(pool, actor, repo, Read)
  pool.with_client(client => {
    let row = client.query_opt(
      "SELECT r.id, r.team_id FROM repository AS r JOIN team AS t ON t.id = r.team_id WHERE t.name_key = ? AND r.name = ? AND r.ready = 1",
      params=[repo.owner, repo.name],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="repository not found or access denied")
    }
    { id: row.get_name("id"), team_id: row.get_name("team_id"), repo, }
  })
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
