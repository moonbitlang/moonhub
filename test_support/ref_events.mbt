///|
pub struct RefEvent {
  reference : String
  commit_sha : String
  state : String
  error : String
}

///|
pub fn ref_events(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
) -> Array[RefEvent] raise {
  pool.with_client(client => {
    client
    .query_all(
      "SELECT reference, new_sha, state, last_error FROM repository_ref_event WHERE repository_id = ? ORDER BY id DESC LIMIT 10",
      params=[scope.id],
    )
    .map(row => {
      reference: row.get_name("reference"),
      commit_sha: row.get_name("new_sha"),
      state: row.get_name("state"),
      error: row.get_name("last_error"),
    })
  })
}
