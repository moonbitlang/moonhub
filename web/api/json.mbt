///|
fn api_handler(
  handler : async (@moonback.Request) -> Json,
) -> @moonback.Handler {
  (req, res) => {
    let (status, json) = (200, handler(req)) catch {
      err if @async.is_cancellation_error(err) => raise err
      err => {
        let (status, code, message) = match err {
          @domain.Unauthorized(message~) => (401, "unauthorized", message)
          @domain.Forbidden(message~) => (403, "forbidden", message)
          @domain.NotFound(message~) => (404, "not_found", message)
          @domain.BadRequest(message~) => (400, "invalid_request", message)
          @pipeline.Conflict(message) => (409, "conflict", message)
          @gitops.Failure(message~) =>
            (400, "git_error", @domain.public_merge_block_reason(message))
          _ => (500, "internal_error", @domain.internal_error_message)
        }
        (status, { "error": { "code": code, "message": message } })
      }
    }
    res.send_json(json, status~, headers={
      "Cache-Control": "no-store",
      "Connection": "close",
    })
  }
}

///|
fn api_actor(
  pool : @database.Database,
  req : @moonback.Request,
  permission : String,
) -> @domain.CurrentUser raise {
  guard req.headers.get("Sec-Fetch-Site") != Some("cross-site") else {
    raise @domain.Forbidden(message="cross-site request rejected")
  }
  let headers = req.headers.get_all("authorization")
  guard headers.length() == 1 &&
    headers[0].length() <= 80 &&
    headers[0].split_once(" ") is Some((scheme, token)) &&
    scheme.to_lower() == "bearer" else {
    raise @domain.Unauthorized(message="bearer access token required")
  }
  @identity.authenticate_access_token(pool, token.to_owned(), permission)
}

///|
async fn api_body(
  req : @moonback.Request,
  allowed : Array[String],
) -> Map[String, Json] {
  let mime = req.headers
    .get("content-type")
    .unwrap_or("")
    .split(";")
    .next()
    .unwrap_or("")
  guard mime.trim().to_lower() == "application/json" else {
    raise @domain.BadRequest(message="application/json required")
  }
  let bytes : Array[Byte] = []
  let reader = req.body.reader()
  @async.with_timeout(
    10000,
    () => {
      while reader.read_some(max_len=4096) is Some(chunk) {
        guard bytes.length() + chunk.length() <= 65536 else {
          raise @domain.BadRequest(message="request body exceeds 64 KiB")
        }
        for byte in chunk {
          bytes.push(byte)
        }
      }
    },
    error=@domain.BadRequest(message="request body timed out"),
  )
  let json = @json.parse(@utf8.decode(Bytes::from_array(bytes))) catch {
    _ => raise @domain.BadRequest(message="invalid UTF-8 JSON body")
  }
  guard json is Object(fields) else {
    raise @domain.BadRequest(message="JSON object required")
  }
  for key, _ in fields {
    guard allowed.contains(key) else {
      raise @domain.BadRequest(message="unsupported request field: \{key}")
    }
  }
  fields
}

///|
fn field(
  fields : Map[String, Json],
  key : String,
  fallback? : String,
) -> String raise {
  match fields.get(key) {
    Some(String(value)) => value
    None if fallback is Some(value) => value
    _ => raise @domain.BadRequest(message="string field required: \{key}")
  }
}

///|
fn number(value : String, zero~ : Bool = false) -> Int64 raise {
  guard !value.is_empty() &&
    value.length() <= 19 &&
    value.iter().all(ch => ch.is_ascii_digit()) &&
    (value == "0" || !value.has_prefix("0")) else {
    raise @domain.BadRequest(message="canonical decimal number required")
  }
  let parsed = @string.parse_int64(value) catch {
    _ => raise @domain.BadRequest(message="invalid number")
  }
  guard parsed > 0L || (zero && parsed == 0L) else {
    raise @domain.BadRequest(message="positive number required")
  }
  parsed
}

///|
fn page(req : @moonback.Request) -> Int64 raise {
  let page = number(req.query().get("page").unwrap_or("1"))
  guard page <= 100000L else {
    raise @domain.BadRequest(message="invalid page")
  }
  page
}

///|
fn mr_json(mr : @collaboration.MergeRequest) -> Json {
  {
    "number": mr.number.to_string(),
    "title": mr.title,
    "description": mr.description,
    "author": mr.author,
    "source": mr.source,
    "target": mr.target,
    "draft": mr.draft,
    "status": mr.status,
    "version": mr.version.to_string(),
    "edit_version": mr.edit_version.to_string(),
    "merged_sha": mr.merged_sha,
    "merge_status": mr.job_status,
    "merge_error": @domain.public_merge_job_error(mr.job_error),
  }
}

///|
fn issue_json(issue : @collaboration.Issue) -> Json {
  {
    "number": issue.number.to_string(),
    "title": issue.title,
    "description": issue.description,
    "author": issue.author,
    "assignee": issue.assignee,
    "assignee_id": issue.assignee_id.to_string(),
    "status": issue.status,
    "edit_version": issue.edit_version.to_string(),
    "updated_at": issue.updated_at,
  }
}

///|
fn run_json(run : @pipeline.Run) -> Json {
  let status = match run.state {
    Queued => "queued"
    Running => "running"
    Completed => "completed"
  }
  let conclusion = conclusion_json(run.conclusion)
  {
    "number": run.number.to_string(),
    "workflow": run.workflow_path,
    "name": run.workflow_name,
    "branch": run.source_branch,
    "commit_sha": run.commit_sha,
    "status": status,
    "conclusion": conclusion,
    "created_at": run.created_at,
  }
}

///|
fn conclusion_json(conclusion : @pipeline.Conclusion?) -> String {
  match conclusion {
    None => ""
    Some(Success) => "success"
    Some(Failure) => "failure"
    Some(Cancelled) => "cancelled"
    Some(TimedOut) => "timed_out"
    Some(Lost) => "lost"
    Some(Skipped) => "skipped"
  }
}

///|
fn check_json(check : @collaboration.MergeCheck) -> Json {
  {
    "workflow": check.workflow_path,
    "status": check.state,
    "conclusion": check.conclusion,
    "run_number": check.run_number.map(id => id.to_string()).unwrap_or(""),
    "error": check.error,
  }
}
