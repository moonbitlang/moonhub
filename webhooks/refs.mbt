///|
async fn recover_refs(
  pool : @database.Database,
  root : String,
  after~ : Int64 = 0L,
) -> Int64 {
  let rows = pool.with_client(client => {
    client.query_all(
      "SELECT DISTINCT r.id,r.team_id,r.name,t.name_key AS owner FROM webhook_ref_intent e JOIN repository r ON r.id=e.repository_id JOIN team t ON t.id=r.team_id WHERE e.state='prepared' AND r.id>? ORDER BY r.id LIMIT 20",
      params=[after],
    )
  })
  let mut cursor = 0L
  for row in rows {
    let scope : @repository.RepositoryScope = {
      id: row.get_name("id"),
      team_id: row.get_name("team_id"),
      repo: { owner: row.get_name("owner"), name: row.get_name("name"), },
    }
    // Advance even when this repository needs operator intervention.
    cursor = scope.id
    try {
      let dir = @repository.resolve_repository_dir(root, scope.repo)
      let lock = @gitops.repository_write_lock(dir)
      defer lock.close()
      @repository.recover_webhook_refs_locked(pool, scope, dir)
    } catch {
      _ =>
        println(
          "webhook push recovery requires inspection for repository \{scope.id}",
        )
    }
  }
  cursor
}
