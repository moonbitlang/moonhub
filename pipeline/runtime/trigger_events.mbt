///|
pub struct TriggerEvent {
  id : Int64
  reference : String
  commit_sha : String
  state : String
  error : String
  created_at : String
  runs : Array[Run]
}

///|
pub fn list_trigger_events(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> Array[TriggerEvent] raise {
  let scope = @repository.repository_scope(pool, actor, repo)
  pool.with_client(client => {
    let rows = client.query_all(
      "SELECT * FROM repository_ref_event WHERE repository_id = ? ORDER BY id DESC LIMIT 10",
      params=[scope.id],
    )
    let runs : Map[Int64, Array[Run]] = Map([])
    for
      row in client.query_all(
        "SELECT p.* FROM pipeline_run p WHERE p.repository_id = ? AND p.trigger_event_id IN (SELECT id FROM repository_ref_event WHERE repository_id = ? ORDER BY id DESC LIMIT 10) ORDER BY p.number",
        params=[scope.id, scope.id],
      ) {
      let id : Int64 = row.get_name("trigger_event_id")
      let group = runs.get_or_default(id, [])
      group.push(Run::from_row(row))
      runs[id] = group
    }
    rows.map(row => {
      let id : Int64 = row.get_name("id")
      {
        id,
        reference: row.get_name("reference"),
        commit_sha: row.get_name("new_sha"),
        state: row.get_name("state"),
        error: row.get_name("last_error"),
        created_at: row.get_name("created_at"),
        runs: runs.get_or_default(id, []),
      }
    })
  })
}
