///|
pub fn Coordinator::api_runtime(
  self : Coordinator,
  id : Int64,
  token : String,
  request : @protocol.OidcRuntimeRequest,
) -> @protocol.ApiRuntime raise {
  check_version(request.version)
  self.authenticate_attempt(id, token)
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        let now = (self.clock)()
        let row = artifact_live(tx, id, request.execution_id, now)
        guard (row.get_name("definition_version") : Int64) >= 8L &&
          attempt_job(row).api_permissions != 0 else {
          raise @domain.Forbidden(message="job API permissions required")
        }
        let count : Int64 = tx
          .query_one(
            "SELECT count(*) n FROM pipeline_api_runtime WHERE attempt_id=?",
            params=[id],
          )
          .get_name("n")
        guard count < 128L else {
          raise @domain.BadRequest(message="too many job API grants")
        }
        let credential = @identity.random_hex(32)
        ignore(
          tx.execute(
            "INSERT INTO pipeline_api_runtime(token_hash,attempt_id,execution_id,expires_ms) VALUES(?,?,?,?)",
            params=[
              @identity.hash_token(credential),
              id,
              request.execution_id,
              (row.get_name("deadline_ms") : Int64),
            ],
          ),
        )
        ignore(
          tx.execute(
            "INSERT INTO pipeline_secret_delivery(attempt_id,step_id,env_name,value) VALUES(?,?,?,?)",
            params=[id, "@api", @identity.hash_token(credential), credential],
          ),
        )
        { token: credential, }
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::authenticate_job_api(
  self : Coordinator,
  token : String,
  repo : @domain.RepoId,
  permission : String,
) -> @domain.CurrentUser raise {
  check_token(token)
  let username = self.pool.with_client(c => {
    c.with_transaction(tx => {
      let now = (self.clock)()
      let grant = tx.query_opt(
        "SELECT * FROM pipeline_api_runtime WHERE token_hash=? AND expires_ms>?",
        params=[@identity.hash_token(token), now],
      )
      guard grant is Some(grant) else {
        raise @domain.Unauthorized(message="invalid job API credential")
      }
      let row = artifact_live(
        tx,
        grant.get_name("attempt_id"),
        grant.get_name("execution_id"),
        now,
      )
      guard (row.get_name("owner_name") : String) == repo.owner &&
        (row.get_name("repo_name") : String) == repo.name else {
        raise @domain.Forbidden(message="job API repository mismatch")
      }
      let job = attempt_job(row)
      let allowed = match permission {
        "contents:read" => job.contents_read
        "contents:write" => job.api_permissions.land(2) != 0
        "actions:read" => job.api_permissions.land(4) != 0
        _ => false
      }
      guard allowed else {
        raise @domain.Forbidden(message="job API permission denied")
      }
      if permission == "contents:write" {
        let run = tx.query_one(
          "SELECT merge_check_id,context_json FROM pipeline_run WHERE id=?",
          params=[(row.get_name("run_id") : Int64)],
        )
        let context : @workflow.RunContext = @json.from_json(
          @json.parse((run.get_name("context_json") : String?).unwrap_or("{}")),
        )
        guard (run.get_name("merge_check_id") : Int64?) is None &&
          ["push", "workflow_dispatch", "schedule"].contains(context.event_name) else {
          raise @domain.Forbidden(
            message="untrusted runs cannot publish releases",
          )
        }
      }
      (
        tx
        .query_one("SELECT name_key FROM user WHERE id=? AND status='active'", params=[
          (row.get_name("requested_by_user_id") : Int64),
        ])
        .get_name("name_key") : String)
    })
  })
  @identity.active_user_by_name(self.pool, username)
}
