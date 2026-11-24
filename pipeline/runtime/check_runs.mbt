///|
fn report_text(
  tx : @database.DbTransaction,
  attempt : Int64,
  text : String,
  extra~ : Array[String] = [],
) -> String raise {
  let masks : Array[String] = extra.copy()
  for
    row in tx.query_all(
      "SELECT value FROM pipeline_secret_delivery WHERE attempt_id=?",
      params=[attempt],
    ) {
    masks.push_iter(secret_masks(row.get_name("value")).iter())
  }
  mask_log(text, masks, complete=true).0
}

///|
fn check_json(row : @database.DbRow) -> Json raise {
  {
    "id": (row.get_name("id") : Int64).to_double(),
    "name": (row.get_name("name") : String),
    "head_sha": (row.get_name("head_sha") : String),
    "status": (row.get_name("status") : String),
    "conclusion": if (row.get_name("conclusion") : String).is_empty() {
      Json::null()
    } else {
      Json::string(row.get_name("conclusion"))
    },
    "output": @json.parse((row.get_name("output_json") : String)),
    "writer": {
      "user_id": (row.get_name("writer_id") : Int64).to_double(),
      "attempt_id": (row.get_name("attempt_id") : Int64).to_double(),
      "run_record_id": (row.get_name("run_id") : Int64).to_double(),
    },
    "created_at": (row.get_name("created_at") : String),
    "updated_at": (row.get_name("updated_at") : String),
  }
}

///|
pub fn Coordinator::write_check_run(
  self : Coordinator,
  token : String,
  repo : @domain.RepoId,
  fields : Map[String, Json],
  id? : Int64,
) -> Json raise {
  let (actor, attempt) = self.job_api_access(token, repo, "checks:write")
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        let existing = id
          .map(id => {
            tx.query_opt(
              "SELECT * FROM pipeline_check_run WHERE id=? AND repository_id=? AND attempt_id=?",
              params=[id, attempt.repository_id, attempt.id],
            )
          })
          .bind(x => x)
        if id is Some(_) && existing is None {
          raise @domain.Forbidden(
            message="check belongs to another job attempt",
          )
        }
        let string_value : (String, String) -> String raise = (name, fallback) => {
          match fields.get(name) {
            None => fallback
            Some(String(s)) => s
            _ =>
              raise @domain.BadRequest(message="check field must be a string")
          }
        }
        let name = string_value(
          "name",
          existing.map(r => r.get_name("name")).unwrap_or(""),
        )
        guard report_text(tx, attempt.id, name) == name else {
          raise @domain.BadRequest(message="check name cannot contain a secret")
        }
        let sha = string_value(
          "head_sha",
          existing.map(r => r.get_name("head_sha")).unwrap_or(""),
        )
        guard !name.trim().is_empty() &&
          name.length() <= 200 &&
          !name.iter().any(c => c.to_int() < 32) &&
          sha == attempt.commit_sha else {
          raise @domain.BadRequest(
            message="check requires a name and the current job commit",
          )
        }
        if existing is Some(row) && name != (row.get_name("name") : String) {
          raise @domain.BadRequest(message="check name is immutable")
        }
        let conclusion = string_value(
          "conclusion",
          existing.map(r => r.get_name("conclusion")).unwrap_or(""),
        )
        let status = if fields.contains("conclusion") && !conclusion.is_empty() {
          "completed"
        } else {
          string_value(
            "status",
            existing.map(r => r.get_name("status")).unwrap_or("queued"),
          )
        }
        guard ["queued", "in_progress", "completed"].contains(status) &&
          (
            (
              status == "completed" &&
              [
                "success", "failure", "neutral", "cancelled", "skipped", "timed_out",
                "action_required",
              ].contains(conclusion)
            ) ||
            (status != "completed" && conclusion.is_empty())
          ) else {
          raise @domain.BadRequest(message="invalid check status or conclusion")
        }
        let output = match fields.get("output") {
          None => existing.map(r => r.get_name("output_json")).unwrap_or("{}")
          Some(Object(values)) => {
            guard values
              .keys()
              .all(k => ["title", "summary", "text"].contains(k)) else {
              raise @domain.BadRequest(message="unsupported check output field")
            }
            let safe : Map[String, Json] = Map([])
            for key in ["title", "summary", "text"] {
              match values.get(key) {
                Some(String(s)) if s.length() <=
                  (if key == "title" { 200 } else { 65535 }) =>
                  safe[key] = Json::string(report_text(tx, attempt.id, s))
                None if key == "text" => ()
                _ =>
                  raise @domain.BadRequest(
                    message="check output requires bounded title and summary",
                  )
              }
            }
            Json::object(safe).stringify()
          }
          _ =>
            raise @domain.BadRequest(message="check output must be an object")
        }
        let check_id = match id {
          Some(id) => {
            ignore(
              tx.execute(
                "UPDATE pipeline_check_run SET status=?,conclusion=?,output_json=?,updated_at=datetime('now') WHERE id=?",
                params=[status, conclusion, output, id],
              ),
            )
            id
          }
          None => {
            let count : Int64 = tx
              .query_one(
                "SELECT count(*) n FROM pipeline_check_run WHERE attempt_id=?",
                params=[attempt.id],
              )
              .get_name("n")
            guard count < 100L else {
              raise @domain.BadRequest(message="job check limit exceeded")
            }
            tx
            .query_one(
              "INSERT INTO pipeline_check_run(repository_id,run_id,attempt_id,writer_id,head_sha,name,status,conclusion,output_json) VALUES(?,?,?,?,?,?,?,?,?) RETURNING id",
              params=[
                attempt.repository_id,
                attempt.run_id,
                attempt.id,
                actor.id,
                sha,
                name,
                status,
                conclusion,
                output,
              ],
            )
            .get_name("id")
          }
        }
        check_json(
          tx.query_one("SELECT * FROM pipeline_check_run WHERE id=?", params=[
            check_id,
          ]),
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn check_runs(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  sha : String,
  page~ : Int64 = 1L,
  per_page~ : Int64 = 30L,
) -> Json raise {
  let scope = @repository.repository_scope(pool, actor, repo)
  @repository.authorize_repository(pool, actor, repo, Read)
  guard sha.length() == 40 &&
    sha.iter().all(c => c.is_ascii_hexdigit()) &&
    page >= 1L &&
    page <= 10000L &&
    per_page >= 1L &&
    per_page <= 100L else {
    raise @domain.BadRequest(message="invalid check query")
  }
  pool.with_client(c => {
    let count : Int64 = c
      .query_one(
        "SELECT count(*) n FROM pipeline_check_run WHERE repository_id=? AND head_sha=?",
        params=[scope.id, sha],
      )
      .get_name("n")
    {
      "total_count": count.to_double(),
      "check_runs": c
      .query_all(
        "SELECT * FROM pipeline_check_run WHERE repository_id=? AND head_sha=? ORDER BY id DESC LIMIT ? OFFSET ?",
        params=[scope.id, sha, per_page, (page - 1L) * per_page],
      )
      .map(check_json),
    }
  })
}
