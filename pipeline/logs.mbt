///|
fn flush_log_tails(
  tx : @database.DbTransaction,
  attempt_id : Int64,
) -> Unit raise {
  for
    row in tx.query_all(
      "SELECT step_id, stream, content FROM pipeline_log_tail WHERE attempt_id = ? ORDER BY step_id, stream",
      params=[attempt_id],
    ) {
    let step : String = row.get_name("step_id")
    let stream : String = row.get_name("stream")
    let text : String = row.get_name("content")
    if !text.is_empty() {
      let _ = tx.execute(
        "INSERT INTO pipeline_log_chunk (attempt_id, step_id, stream, content, payload_hash) VALUES (?, ?, ?, ?, '')",
        params=[attempt_id, step, stream, "***"],
      )
    }
  }
  let _ = tx.execute("DELETE FROM pipeline_log_tail WHERE attempt_id = ?", params=[
    attempt_id,
  ])
  ignore(
    tx.execute("DELETE FROM pipeline_secret_delivery WHERE attempt_id = ?", params=[
      attempt_id,
    ]),
  )
}

///|
pub fn Coordinator::append_log(
  self : Coordinator,
  id : Int64,
  token : String,
  request : @protocol.LogRequest,
) -> @protocol.LeaseState raise {
  check_version(request.version)
  let wire_sequence = parse_protocol_int64(
    request.sequence,
    "invalid log sequence",
  )
  guard wire_sequence > 0 && ["stdout", "stderr"].contains(request.stream) else {
    raise @domain.BadRequest(message="invalid log sequence or stream")
  }
  guard wire_sequence <= @protocol.max_log_chunks else { raise LogLimit }
  let size = @utf8.encode(request.text).length()
  guard size > 0 && size <= @protocol.max_log_chunk_bytes else {
    raise LogLimit
  }
  self.authenticate_attempt(id, token)
  ignore(self.expire_attempts())
  let hash = @identity.hash_token(ToJson::to_json(request).stringify())
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = load_live_attempt(tx, id, token, (self.clock)())
        guard (row.get_name("status") : String) == "running" else {
          raise Conflict("attempt has not started")
        }
        if tx.query_opt(
            "SELECT payload_hash FROM pipeline_log_chunk WHERE attempt_id = ? AND sequence = ?",
            params=[id, wire_sequence],
          )
          is Some(existing) {
          guard (existing.get_name("payload_hash") : String) == hash else {
            raise Conflict("log sequence was reused with different content")
          }
          return lease_state(row, (self.clock)())
        }
        let current_sequence : Int64 = row.get_name("log_sequence")
        let bytes : Int64 = row.get_name("log_bytes")
        guard wire_sequence == current_sequence + 1L else {
          raise Conflict("log chunks must be uploaded in sequence")
        }
        guard bytes + size.to_int64() <= @protocol.max_log_bytes else {
          raise LogLimit
        }
        let job = attempt_job(row)
        guard request.step_id.is_empty() ||
          job.steps.any(step => step.id == request.step_id) else {
          raise @domain.BadRequest(message="unknown log step")
        }
        let previous : String = match
          tx.query_opt(
            "SELECT content FROM pipeline_log_tail WHERE attempt_id = ? AND step_id = ? AND stream = ?",
            params=[id, request.step_id, request.stream],
          ) {
          Some(row) => row.get_name("content")
          None => ""
        }
        let masks = [token]
        for
          delivery in tx.query_all(
            "SELECT DISTINCT value FROM pipeline_secret_delivery WHERE attempt_id = ?",
            params=[id],
          ) {
          masks.push_iter(secret_masks(delivery.get_name("value")).iter())
        }
        let (content, tail) = mask_log(previous + request.text, masks)
        let _ = tx.execute(
          "INSERT INTO pipeline_log_chunk (attempt_id, sequence, step_id, stream, content, payload_hash) VALUES (?, ?, ?, ?, ?, ?)",
          params=[
            id,
            wire_sequence,
            request.step_id,
            request.stream,
            content,
            hash,
          ],
        )
        let _ = tx.execute(
          "INSERT INTO pipeline_log_tail (attempt_id, step_id, stream, content) VALUES (?, ?, ?, ?) ON CONFLICT (attempt_id, step_id, stream) DO UPDATE SET content = excluded.content",
          params=[id, request.step_id, request.stream, tail],
        )
        let _ = tx.execute(
          "UPDATE pipeline_job_attempt SET log_sequence = ?, log_bytes = log_bytes + ? WHERE id = ?",
          params=[wire_sequence, size.to_int64(), id],
        )
        lease_state(attempt_row(tx, id, token), (self.clock)())
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::read_logs(
  self : Coordinator,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  run_number : Int64,
  attempt_id : Int64,
  after~ : Int64 = 0L,
) -> Array[@protocol.LogChunk] raise {
  self.read_log_page(actor, repo, run_number, attempt_id, after~).chunks
}

///|
pub struct LogPage {
  chunks : Array[@protocol.LogChunk]
  next_cursor : String
  has_more : Bool
  complete : Bool
} derive(Debug)

///|
pub fn Coordinator::read_log_page(
  self : Coordinator,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  run_number : Int64,
  attempt_id : Int64,
  after~ : Int64 = 0L,
) -> LogPage raise {
  let run = get_run(self.pool, actor, repo, run_number)
  guard after >= 0L else {
    raise @domain.BadRequest(message="invalid log cursor")
  }
  self.pool.with_client(client => {
    // Completion and the final flushed log tail must come from one snapshot.
    client.with_transaction(tx => {
      guard tx.query_opt(
          "SELECT a.status FROM pipeline_job_attempt a JOIN pipeline_job j ON j.id = a.job_id WHERE a.id = ? AND j.run_id = ?",
          params=[attempt_id, run.id],
        )
        is Some(attempt) else {
        raise @domain.NotFound(message="attempt not found")
      }
      let rows = tx.query_all(
        "SELECT id, step_id, stream, content FROM pipeline_log_chunk WHERE attempt_id = ? AND id > ? ORDER BY id LIMIT 101",
        params=[attempt_id, after],
      )
      let has_more = rows.length() > 100
      if has_more {
        ignore(rows.pop())
      }
      let chunks : Array[@protocol.LogChunk] = rows.map(row => {
        id: (row.get_name("id") : Int64).to_string(),
        step_id: row.get_name("step_id"),
        stream: row.get_name("stream"),
        text: row.get_name("content"),
      })
      {
        chunks,
        next_cursor: chunks
        .last()
        .map(chunk => chunk.id)
        .unwrap_or(after.to_string()),
        has_more,
        complete: (attempt.get_name("status") : String) == "completed" &&
        !has_more,
      }
    })
  })
}
