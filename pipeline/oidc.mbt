///|
fn Coordinator::oidc_issuer(self : Coordinator) -> OidcIssuer raise {
  guard self.oidc is Some(issuer) else {
    raise @domain.BadRequest(message="workflow OIDC is not configured")
  }
  issuer
}

///|
fn oidc_live(
  tx : @database.DbTransaction,
  attempt : Int64,
  execution : String,
  now : Int64,
) -> @database.DbRow raise {
  let row = artifact_live(tx, attempt, execution, now)
  guard (row.get_name("definition_version") : Int64) >= 7L &&
    attempt_job(row).id_token_write else {
    raise @domain.Unauthorized(message="job does not grant id-token: write")
  }
  row
}

///|
pub fn Coordinator::oidc_runtime(
  self : Coordinator,
  id : Int64,
  token : String,
  request : @protocol.OidcRuntimeRequest,
) -> @protocol.OidcRuntime raise {
  check_version(request.version)
  let issuer = self.oidc_issuer()
  self.authenticate_attempt(id, token)
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let now = (self.clock)()
        let row = oidc_live(tx, id, request.execution_id, now)
        // Retain expired grants until completion so issuance budgets cannot
        // reset during a long-running attempt.
        let count : Int64 = tx
          .query_one(
            "SELECT COUNT(*) AS count FROM pipeline_oidc_runtime WHERE attempt_id=?",
            params=[id],
          )
          .get_name("count")
        guard count < 128L else {
          raise @domain.BadRequest(message="too many OIDC runtime grants")
        }
        let credential = @identity.random_hex(32)
        let expires = Int64::min(now + 3600000L, row.get_name("deadline_ms"))
        ignore(
          tx.execute(
            "INSERT INTO pipeline_oidc_runtime(token_hash,attempt_id,execution_id,expires_ms) VALUES(?,?,?,?)",
            params=[
              @identity.hash_token(credential),
              id,
              request.execution_id,
              expires,
            ],
          ),
        )
        ignore(
          tx.execute(
            "INSERT INTO pipeline_secret_delivery(attempt_id,step_id,env_name,value) VALUES(?,?,?,?)",
            params=[id, "@oidc", @identity.hash_token(credential), credential],
          ),
        )
        {
          token: credential,
          request_url: issuer.issuer +
          "/-/oidc/token?attempt_id=" +
          id.to_string(),
        }
      },
      immediate=true,
    )
  })
}

///|
fn Coordinator::oidc_claims(
  self : Coordinator,
  id : Int64,
  token : String,
  audience : String,
  consume : Bool,
) -> Json raise {
  check_token(token)
  let issuer = self.oidc_issuer()
  let audience = if audience.is_empty() {
    issuer.audiences[0]
  } else {
    audience
  }
  guard issuer.audiences.contains(audience) else {
    raise @domain.BadRequest(message="OIDC audience is not allowed")
  }
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let now = (self.clock)()
        let hash = @identity.hash_token(token)
        let grant = tx.query_opt(
          "SELECT * FROM pipeline_oidc_runtime WHERE token_hash=? AND attempt_id=? AND expires_ms>?",
          params=[hash, id, now],
        )
        guard grant is Some(grant) else {
          raise @domain.Unauthorized(message="invalid OIDC request credential")
        }
        let row = oidc_live(tx, id, grant.get_name("execution_id"), now)
        let count : Int64 = tx
          .query_one(
            "SELECT COALESCE(SUM(requests),0) AS count FROM pipeline_oidc_runtime WHERE attempt_id=?",
            params=[id],
          )
          .get_name("count")
        guard !consume || count < 256L else {
          raise @domain.BadRequest(message="OIDC request limit exceeded")
        }
        if consume {
          ignore(
            tx.execute(
              "UPDATE pipeline_oidc_runtime SET requests=requests+1 WHERE token_hash=?",
              params=[hash],
            ),
          )
        }
        let run = tx.query_one(
          "SELECT r.*, m.number AS mr_number FROM pipeline_run r LEFT JOIN merge_check c ON c.id=r.merge_check_id LEFT JOIN merge_request m ON m.id=c.merge_request_id WHERE r.id=?",
          params=[(row.get_name("run_id") : Int64)],
        )
        let context : @workflow.RunContext = @json.from_json(
          @json.parse((run.get_name("context_json") : String?).unwrap_or("{}")),
        )
        let repository_id : Int64 = row.get_name("repository_id")
        let repo = context.repository
        let event_ref = if context.event_name == "pull_request" {
          "refs/pull/" +
          (run.get_name("mr_number") : Int64).to_string() +
          "/merge"
        } else {
          "refs/heads/" + (run.get_name("source_branch") : String)
        }
        let subject = "repo_id:" +
          repository_id.to_string() +
          (if context.event_name == "pull_request" {
            ":pull_request"
          } else {
            ":ref:" +
            event_ref
            .replace_all(old="%", new="%25")
            .replace_all(old=":", new="%3A")
          })
        let expires = Int64::min(now + 300000L, row.get_name("deadline_ms")) /
          1000L
        guard expires > now / 1000L else {
          raise @domain.Unauthorized(message="job is expiring")
        }
        {
          "iss": issuer.issuer,
          "sub": subject,
          "aud": audience,
          "iat": (now / 1000L).to_double(),
          "nbf": (now / 1000L).to_double(),
          "exp": expires.to_double(),
          "jti": @identity.random_hex(16),
          "repository": repo,
          "repository_id": repository_id.to_string(),
          "ref": event_ref,
          "sha": (row.get_name("commit_sha") : String),
          "run_id": (row.get_name("run_id") : Int64).to_string(),
          "job_id": (row.get_name("job_key") : String),
          "event_name": context.event_name,
          "workflow_ref": repo +
          "/" +
          (run.get_name("workflow_path") : String) +
          "@" +
          (row.get_name("commit_sha") : String),
        }
      },
      immediate=true,
    )
  })
}

///|
pub async fn Coordinator::oidc_token(
  self : Coordinator,
  id : Int64,
  token : String,
  audience : String,
) -> Json {
  let issuer = self.oidc_issuer()
  // Authenticate before using a signing slot, then recheck after queueing and
  // after signing. Cancellation/revocation during either wait cannot issue a token.
  ignore(self.oidc_claims(id, token, audience, false))
  @async.with_timeout(10000, () => issuer.signing.acquire())
  defer issuer.signing.release()
  let claims = self.oidc_claims(id, token, audience, true)
  let jwt = issuer.sign(claims)
  ignore(self.oidc_claims(id, token, audience, false))
  self.pool.with_client(client => {
    ignore(
      client.execute(
        "INSERT INTO pipeline_secret_delivery(attempt_id,step_id,env_name,value) VALUES(?,?,?,?)",
        params=[id, "@oidc", @identity.hash_token(jwt), jwt],
      ),
    )
  })
  { "value": jwt }
}

///|
pub fn Coordinator::oidc_discovery(self : Coordinator) -> Json raise {
  self.oidc_issuer().discovery()
}

///|
pub fn Coordinator::oidc_jwks(self : Coordinator) -> Json raise {
  self.oidc_issuer().jwks()
}
