///|
async fn recover_refs(pool : @database.Database, root : String) -> Unit {
  let rows = pool.with_client(client => {
    client.query_all(
      "SELECT DISTINCT r.id,r.team_id,r.name,t.name_key AS owner FROM webhook_ref_intent e JOIN repository r ON r.id=e.repository_id JOIN team t ON t.id=r.team_id WHERE e.state='prepared' ORDER BY r.id LIMIT 20",
    )
  })
  for row in rows {
    let scope : @repository.RepositoryScope = {
      id: row.get_name("id"),
      team_id: row.get_name("team_id"),
      repo: { owner: row.get_name("owner"), name: row.get_name("name"), },
    }
    try {
      let dir = @repository.resolve_repository_dir(root, scope.repo)
      let lock = @gitops.repository_write_lock(dir)
      defer lock.close()
      @repository.recover_webhook_refs_locked(pool, scope, dir)
    } catch {
      err if @async.is_cancellation_error(err) => raise err
      _ =>
        println(
          "webhook push recovery requires inspection for repository \{scope.id}",
        )
    }
  }
}
