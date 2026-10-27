///|
// Refresh requested reviews even when the repository has no required CI checks.
// A persisted cursor prevents missing branches from starving other requests.
pub async fn refresh_next_requested_review(
  pool : @database.Database,
  root : String,
) -> Bool {
  let row = pool.with_client(client => {
    client.query_opt(
      "SELECT m.number, m.id, r.id AS repository_id, r.team_id, r.name, t.name_key AS owner FROM merge_request m JOIN repository r ON r.id = m.repository_id JOIN team t ON t.id = r.team_id WHERE r.ready = 1 AND m.status = 'open' AND m.draft = 0 AND m.reviews_poll_after <= CAST(strftime('%s', 'now') AS INTEGER) AND EXISTS (SELECT 1 FROM merge_review_request q JOIN collaboration_access a ON a.repository_id = r.id AND a.user_id = q.user_id AND a.contributor = 1 WHERE q.merge_request_id = m.id) ORDER BY m.reviews_poll_after, m.id LIMIT 1",
    )
  })
  guard row is Some(row) else { return false }
  let id : Int64 = row.get_name("id")
  pool.with_client(client => {
    ignore(
      client.execute(
        "UPDATE merge_request SET reviews_poll_after = CAST(strftime('%s', 'now') AS INTEGER) + 5 WHERE id = ?",
        params=[id],
      ),
    )
  })
  let scope : @repository.RepositoryScope = {
    id: row.get_name("repository_id"),
    team_id: row.get_name("team_id"),
    repo: { owner: row.get_name("owner"), name: row.get_name("name"), },
  }
  let git_dir = @repository.resolve_repository_dir(root, scope.repo)
  let lock = @gitops.repository_write_lock(git_dir)
  defer lock.close()
  @repository.recover_ref_events_locked(pool, scope, git_dir)
  ignore(
    refresh_merge_request(
      pool,
      scope,
      git_dir,
      require_merge_request(pool, scope, row.get_name("number")),
    ),
  )
  true
}

///|
pub fn start_review_requests_worker(
  pool : @database.Database,
  root : String,
  group : @async.TaskGroup[Unit],
) -> Unit {
  group.spawn_bg(no_wait=true, allow_failure=true, () => {
    for ;; {
      let processed = refresh_next_requested_review(pool, root) catch {
        _ => false
      }
      if !processed {
        @async.sleep(1000)
      }
    }
  })
}
