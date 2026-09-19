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
        params=[attempt_id, step, stream, text],
      )
    }
  }
  let _ = tx.execute("DELETE FROM pipeline_log_tail WHERE attempt_id = ?", params=[
    attempt_id,
  ])
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
        // Hold only a suffix that could become this credential across chunk boundaries.
        let text = (previous + request.text).replace_all(old=token, new="***")
        let mut hold = 0
        for length = 1; length < token.length(); length = length + 1 {
          if text.has_suffix(token[:length]) {
            hold = length
          }
        }
        let content = text[:text.length() - hold].to_owned()
        let tail = text[text.length() - hold:].to_owned()
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
  after? : Int64 = 0L,
) -> Array[@protocol.LogChunk] raise {
  let run = get_run(self.pool, actor, repo, run_number)
  guard after >= 0L else {
    raise @domain.BadRequest(message="invalid log cursor")
  }
  self.pool.with_client(client => {
    guard client.query_opt(
        "SELECT a.id FROM pipeline_job_attempt a JOIN pipeline_job j ON j.id = a.job_id WHERE a.id = ? AND j.run_id = ?",
        params=[attempt_id, run.id],
      )
      is Some(_) else {
      raise @domain.NotFound(message="attempt not found")
    }
    client
    .query_all(
      "SELECT id, step_id, stream, content FROM pipeline_log_chunk WHERE attempt_id = ? AND id > ? ORDER BY id LIMIT 100",
      params=[attempt_id, after],
    )
    .map(row => {
      id: (row.get_name("id") : Int64).to_string(),
      step_id: row.get_name("step_id"),
      stream: row.get_name("stream"),
      text: row.get_name("content"),
    })
  })
}
