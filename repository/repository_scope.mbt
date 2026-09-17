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
    let row = client
      .query_opt(
        "SELECT r.id, r.team_id FROM repository AS r JOIN team AS t ON t.id = r.team_id WHERE t.name_key = ? AND r.name = ? AND r.ready = 1",
        params=[repo.owner, repo.name],
      )
      .unwrap()
    { id: row.get_name("id"), team_id: row.get_name("team_id"), repo, }
  })
}

///|
pub async fn[A] with_repository_write(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  f : async (RepositoryScope, String) -> A,
) -> A {
  authorize_repository(pool, actor, repo, Write)
  let git_dir = resolve_repository_dir(root, repo)
  let lock = @gitops.repository_write_lock(git_dir)
  defer lock.close()
  authorize_repository(pool, actor, repo, Write)
  f(repository_scope(pool, actor, repo), git_dir)
}
