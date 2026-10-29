///|
fn record_mirror_refs(
  tx : @database.DbTransaction,
  repository_id : Int64,
  source_key : String,
  phase : String,
  updates : String,
) -> Unit raise {
  for line in @domain.split_lines(updates) {
    let fields = line.split(" ").map(part => part.to_owned()).collect()
    guard fields.length() == 3 else {
      raise @domain.BadRequest(message="invalid ref update")
    }
    if !fields[2].has_prefix("refs/heads/") &&
      !fields[2].has_prefix("refs/tags/") {
      continue
    }
    guard @gitops.valid_commit_sha(fields[0]) &&
      @gitops.valid_commit_sha(fields[1]) else {
      raise @domain.BadRequest(message="invalid ref object IDs")
    }
    if fields[0] == fields[1] {
      continue
    }
    if phase == "prepared" {
      ignore(
        tx.execute(
          "INSERT OR IGNORE INTO mirror_ref_intent(repository_id,source_key,reference,old_sha,new_sha,state) SELECT ?,?,?,?,?,'prepared' WHERE EXISTS(SELECT 1 FROM repository_mirror WHERE repository_id=? AND active=1)",
          params=[
            repository_id,
            source_key,
            fields[2],
            fields[0],
            fields[1],
            repository_id,
          ],
        ),
      )
    } else {
      ignore(
        tx.execute(
          "UPDATE mirror_ref_intent SET state=? WHERE repository_id=? AND source_key=? AND reference=? AND old_sha=? AND new_sha=? AND state='prepared'",
          params=[
            if phase == "committed" {
              "ready"
            } else {
              "aborted"
            },
            repository_id,
            source_key,
            fields[2],
            fields[0],
            fields[1],
          ],
        ),
      )
    }
  }
}

///|
async fn recover_mirror_refs_locked(
  pool : @database.Database,
  scope : RepositoryScope,
  git_dir : String,
) -> Unit {
  let rows = pool.with_client(client => {
    client.query_all(
      "SELECT * FROM mirror_ref_intent WHERE repository_id=? AND state='prepared' ORDER BY id",
      params=[scope.id],
    )
  })
  for row in rows {
    let reference : String = row.get_name("reference")
    let old : String = row.get_name("old_sha")
    let next : String = row.get_name("new_sha")
    let (code, output) = @gitops.merge_git_command(git_dir, [
      "rev-parse", "--verify", "--quiet", reference,
    ])
    let state = if (code == 1 && next.iter().all(ch => ch == '0')) ||
      (code == 0 && output.trim() == next) {
      "ready"
    } else if (code == 1 && old.iter().all(ch => ch == '0')) ||
      (code == 0 && output.trim() == old) {
      "aborted"
    } else {
      raise @domain.BadRequest(
        message="unconfirmed mirror ref update; inspect repository refs before further writes",
      )
    }
    let id : Int64 = row.get_name("id")
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE mirror_ref_intent SET state=? WHERE id=? AND state='prepared'",
          params=[state, id],
        ),
      )
    })
  }
  pool.with_client(client => {
    ignore(
      client.execute(
        "DELETE FROM mirror_ref_intent WHERE repository_id=? AND state<>'prepared'",
        params=[scope.id],
      ),
    )
  })
}
