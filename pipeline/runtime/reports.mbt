///|
// Reports are masked before truncation so a clipped secret cannot become an
// unrecognizable prefix. Keep the cut on a UTF-8 code point boundary.
fn bounded_report_text(text : String, limit : Int32) -> (String, Bool) {
  let bytes = @utf8.encode(text)
  if bytes.length() <= limit {
    return (text, false)
  }
  let mut cut = limit
  while cut > 0 && bytes[cut].to_int() >= 0x80 && bytes[cut].to_int() <= 0xbf {
    cut -= 1
  }
  (@utf8.decode_lossy(bytes[:cut]), true)
}

///|
pub fn Coordinator::write_report(
  self : Coordinator,
  id : Int64,
  token : String,
  request : @protocol.ReportRequest,
) -> @protocol.LeaseState raise {
  check_version(request.version)
  self.authenticate_attempt(id, token)
  let report = request.report
  guard report.revision >= 1 &&
    report.revision <= 256 &&
    report.entries.length() <= 64 else {
    raise @domain.BadRequest(message="invalid report revision or step count")
  }
  let raw = ToJson::to_json(report).stringify()
  guard @utf8.encode(raw).length() <= 4194304 else {
    raise @domain.BadRequest(message="report exceeds limits")
  }
  let digest = @identity.hash_token(raw)
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        let now = (self.clock)()
        let live = live_attempt(tx, id, request.execution_id, now)
        guard live.definition_version >= 9 && live.job().reports else {
          raise @domain.Forbidden(
            message="reporting is unavailable for this snapshot",
          )
        }
        let row = load_live_attempt(tx, id, token, now)
        let previous = tx.query_opt(
          "SELECT revision,payload_hash,content_json FROM pipeline_attempt_report WHERE attempt_id=?",
          params=[id],
        )
        if previous is Some(old) {
          let revision : Int64 = old.get_name("revision")
          if revision == report.revision.to_int64() &&
            (old.get_name("payload_hash") : String) == digest {
            return lease_state(row, now)
          }
          guard report.revision.to_int64() > revision else {
            raise Conflict("stale or conflicting report revision")
          }
        }
        let seen : Map[String, Bool] = Map([])
        let mut summary_bytes = 0
        let mut annotation_bytes = 0
        let mut annotation_count = 0
        let mut stored_summary_bytes = 0
        let mut stored_annotation_bytes = 0
        let mut annotations_full = false
        let mut truncated = report.truncated
        let bounded = (text, limit) => {
          let (value, clipped) = bounded_report_text(text, limit)
          truncated = truncated || clipped
          value
        }
        let entries = report.entries.map(entry => {
          guard !seen.contains(entry.step_id) &&
            tx.query_opt(
              "SELECT step_id FROM pipeline_step WHERE attempt_id=? AND step_id=? AND state<>'pending'",
              params=[id, entry.step_id],
            )
            is Some(_) else {
            raise @domain.BadRequest(
              message="unknown duplicate or unstarted report step",
            )
          }
          seen[entry.step_id] = true
          summary_bytes += @utf8.encode(entry.summary).length()
          guard summary_bytes <= 1048576 && !entry.summary.contains("\u{0000}") else {
            raise @domain.BadRequest(message="summary exceeds limits")
          }
          let summary = bounded(
            report_text(tx, id, entry.summary, extra=[token]),
            1048576 - stored_summary_bytes,
          )
          stored_summary_bytes += @utf8.encode(summary).length()
          let annotations = entry.annotations.filter_map(a => {
            annotation_count += 1
            annotation_bytes += @utf8.encode(ToJson::to_json(a).stringify()).length()
            guard annotation_count <= 200 &&
              annotation_bytes <= 262144 &&
              ["notice", "warning", "error"].contains(a.severity) &&
              a.message.length() <= 16384 &&
              a.title.length() <= 200 &&
              a.file.length() <= 1024 &&
              !a.file.iter().any(c => c.to_int() < 32) &&
              !a.message.contains("\u{0000}") &&
              !a.title.contains("\u{0000}") &&
              a.line >= 0 &&
              a.end_line >= a.line &&
              a.column >= 0 &&
              a.end_column >= 0 &&
              (a.end_line > a.line || a.end_column >= a.column) &&
              (
                a.line > 0 ||
                (a.end_line == 0 && a.column == 0 && a.end_column == 0)
              ) else {
              raise @domain.BadRequest(
                message="invalid annotation or exceeded report limits",
              )
            }
            if annotations_full {
              return None
            }
            let value = {
              ..a,
              message: bounded(
                report_text(tx, id, a.message, extra=[token]),
                16384,
              ),
              title: bounded(report_text(tx, id, a.title, extra=[token]), 200),
              file: bounded(report_text(tx, id, a.file, extra=[token]), 1024),
            }
            let bytes = @utf8.encode(ToJson::to_json(value).stringify()).length()
            if stored_annotation_bytes + bytes > 262144 {
              truncated = true
              annotations_full = true
              None
            } else {
              stored_annotation_bytes += bytes
              Some(value)
            }
          })
          { ..entry, summary, annotations, }
        })
        let content = ToJson::to_json({ ..report, entries, truncated, }).stringify()
        let existing_size : Int64 = tx
          .query_one(
            "SELECT COALESCE(SUM(length(CAST(p.content_json AS BLOB))),0) n FROM pipeline_attempt_report p JOIN pipeline_job_attempt a ON a.id=p.attempt_id JOIN pipeline_job j ON j.id=a.job_id WHERE j.run_id=? AND p.attempt_id<>?",
            params=[live.run_id, id],
          )
          .get_name("n")
        let remaining = 8388608L - existing_size
        let content = if @utf8.encode(content).length().to_int64() <= remaining {
          content
        } else {
          // Keep the last published entries when the shared storage budget
          // fills while this job is running.
          let entries = match previous {
            Some(old) => {
              let saved : @protocol.JobReport = @json.from_json(
                @json.parse((old.get_name("content_json") : String)),
              )
              saved.entries
            }
            None => []
          }
          ToJson::to_json({ ..report, entries, truncated: true, }).stringify()
        }
        if @utf8.encode(content).length().to_int64() > remaining {
          return lease_state(row, now)
        }
        ignore(
          tx.execute(
            "INSERT INTO pipeline_attempt_report(attempt_id,revision,payload_hash,content_json) VALUES(?,?,?,?) ON CONFLICT(attempt_id) DO UPDATE SET revision=excluded.revision,payload_hash=excluded.payload_hash,content_json=excluded.content_json",
            params=[id, report.revision.to_int64(), digest, content],
          ),
        )
        lease_state(row, now)
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::read_report(
  self : Coordinator,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
  id : Int64,
) -> @protocol.JobReport raise {
  let run = get_run(self.pool, actor, repo, number)
  self.pool.with_client(c => {
    guard c.query_opt(
        "SELECT a.id FROM pipeline_job_attempt a JOIN pipeline_job j ON j.id=a.job_id WHERE a.id=? AND j.run_id=?",
        params=[id, run.id],
      )
      is Some(_) else {
      raise @domain.NotFound(message="attempt not found")
    }
    match
      c.query_opt(
        "SELECT content_json FROM pipeline_attempt_report WHERE attempt_id=?",
        params=[id],
      ) {
      Some(row) =>
        @json.from_json(@json.parse((row.get_name("content_json") : String)))
      None => { revision: 0, entries: [], truncated: false, }
    }
  })
}
