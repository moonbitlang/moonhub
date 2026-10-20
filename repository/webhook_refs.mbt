///|
// Capture outbound notifications independently of CI execution permission.
fn record_webhook_refs(
  tx : @database.DbTransaction,
  scope : RepositoryScope,
  actor_id : Int64,
  source_key : String,
  phase : String,
  updates : String,
  deploy_key_id~ : Int64 = 0L,
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
          "INSERT OR IGNORE INTO webhook_ref_intent(repository_id,actor_id,deploy_key_id,source_key,reference,old_sha,new_sha,state) SELECT ?,NULLIF(?,0),NULLIF(?,0),?,?,?,?,'prepared' WHERE EXISTS(SELECT 1 FROM repository_webhook WHERE repository_id=? AND active=1 AND instr(',' || events || ',',',push,')>0)",
          params=[
            scope.id,
            actor_id,
            deploy_key_id,
            source_key,
            fields[2],
            fields[0],
            fields[1],
            scope.id,
          ],
        ),
      )
    } else {
      ignore(
        tx.execute(
          "UPDATE webhook_ref_intent SET state=? WHERE repository_id=? AND source_key=? AND reference=? AND old_sha=? AND new_sha=? AND state='prepared'",
          params=[
            if phase == "committed" {
              "ready"
            } else {
              "aborted"
            },
            scope.id,
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
pub async fn recover_webhook_refs_locked(
  pool : @database.Database,
  scope : RepositoryScope,
  git_dir : String,
) -> Unit {
  let rows = pool.with_client(client => {
    client.query_all(
      "SELECT id,reference,old_sha,new_sha FROM webhook_ref_intent WHERE repository_id=? AND state='prepared' ORDER BY id",
      params=[scope.id],
    )
  })
  for row in rows {
    let reference : String = row.get_name("reference")
    let old : String = row.get_name("old_sha")
    let next : String = row.get_name("new_sha")
    let id : Int64 = row.get_name("id")
    let (code, output) = @gitops.merge_git_command(git_dir, [
      "rev-parse", "--verify", "--quiet", reference,
    ])
    let absent = code == 1
    let current = output.trim()
    let state = if (absent && next.iter().all(ch => ch == '0')) ||
      (code == 0 && current == next) {
      "ready"
    } else if (absent && old.iter().all(ch => ch == '0')) ||
      (code == 0 && current == old) {
      "aborted"
    } else {
      raise @domain.BadRequest(
        message="unconfirmed webhook ref update; inspect repository refs before further writes",
      )
    }
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE webhook_ref_intent SET state=? WHERE id=? AND state='prepared'",
          params=[state, id],
        ),
      )
    })
  }
}

///|
pub fn record_deploy_key_webhook_transaction(
  pool : @database.Database,
  scope : RepositoryScope,
  key_id : Int64,
  source_key : String,
  phase : String,
  updates : String,
) -> Unit raise {
  guard ["preparing", "prepared", "committed", "aborted"].contains(phase) &&
    source_key.length() == 32 &&
    source_key.iter().all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f')) else {
    raise @domain.BadRequest(message="invalid reference transaction")
  }
  if phase == "preparing" {
    return
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.query_opt(
          "SELECT id FROM repository_deploy_key WHERE id=? AND repository_id=? AND write_access=1 AND revoked_at IS NULL",
          params=[key_id, scope.id],
        )
        is Some(_) else {
        raise @domain.Forbidden(
          message="deploy key cannot write this repository",
        )
      }
      record_webhook_refs(
        tx,
        scope,
        0L,
        source_key,
        phase,
        updates,
        deploy_key_id=key_id,
      )
    })
  })
}
