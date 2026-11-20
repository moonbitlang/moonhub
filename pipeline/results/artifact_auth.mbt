///|
priv struct ArtifactAccess {
  runtime_hash : String
  attempt_id : Int64
  run_id : Int64
  repository_id : Int64
  origin : String
}

///|
fn base64url(bytes : Bytes) -> String {
  @base64.encode(bytes)
  .replace_all(old="+", new="-")
  .replace_all(old="/", new="_")
  .trim_end(chars="=")
  .to_owned()
}

///|
pub fn Service::artifact_runtime(
  self : Service,
  id : Int64,
  token : String,
  request : @protocol.ArtifactRuntimeRequest,
) -> @protocol.ArtifactRuntime raise {
  guard request.version == @protocol.version else {
    raise @domain.BadRequest(message="unsupported runner protocol version")
  }
  guard request.origin.length() <= 320 &&
    (
      request.origin.has_prefix("https://") ||
      request.origin.has_prefix("http://")
    ) &&
    request.origin.split("://").count() == 2 &&
    !request.origin.split("://").last().unwrap().is_empty() &&
    !request.origin.split("://").last().unwrap().contains("/") &&
    !request.origin.contains("@") &&
    !request.origin.contains("?") &&
    !request.origin.contains("#") &&
    request.origin.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) else {
    raise @domain.BadRequest(message="artifact origin must be a server origin")
  }
  @runtime.Coordinator::new(self.pool).authenticate_attempt(id, token)
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let now = (self.clock)()
        let row = @runtime.live_attempt(tx, id, request.execution_id, now)
        let expires = Int64::min(now + 3600000L, row.deadline_ms)
        let run : Int64 = row.run_id
        let payload : Json = {
          "scp": "Actions.Results:" + run.to_string() + ":" + id.to_string(),
          "exp": (expires / 1000L).to_double(),
        }
        let credential = base64url(
            @utf8.encode("{\"alg\":\"HS256\",\"typ\":\"JWT\"}"),
          ) +
          "." +
          base64url(@utf8.encode(payload.stringify())) +
          "." +
          @identity.random_hex(32)
        let hash = @identity.hash_token(credential)
        // This opaque JWT-shaped credential is validated by its complete hash, not
        // by trusting caller-supplied claims. Never reuse the runner lease token.
        ignore(
          tx.execute(
            "DELETE FROM pipeline_artifact_runtime WHERE attempt_id=? AND expires_ms<=?",
            params=[id, now],
          ),
        )
        guard tx
          .query_all(
            "SELECT token_hash FROM pipeline_artifact_runtime WHERE attempt_id=?",
            params=[id],
          )
          .length() <
          128 else {
          raise @domain.BadRequest(message="too many artifact runtime grants")
        }
        ignore(
          tx.execute(
            "INSERT INTO pipeline_artifact_runtime(token_hash,attempt_id,execution_id,origin,expires_ms) VALUES(?,?,?,?,?)",
            params=[hash, id, request.execution_id, request.origin, expires],
          ),
        )
        {
          token: credential,
          results_url: request.origin,
          expires_ms: expires.to_string(),
        }
      },
      immediate=true,
    )
  })
}

///|
fn artifact_access(
  tx : @database.DbTransaction,
  hash : String,
  now : Int64,
) -> ArtifactAccess raise {
  let grant = tx.query_opt(
    "SELECT * FROM pipeline_artifact_runtime WHERE token_hash=? AND expires_ms>?",
    params=[hash, now],
  )
  guard grant is Some(grant) else {
    raise @domain.Unauthorized(message="invalid artifact runtime")
  }
  let id : Int64 = grant.get_name("attempt_id")
  let row = @runtime.live_attempt(tx, id, grant.get_name("execution_id"), now)
  {
    runtime_hash: hash,
    attempt_id: id,
    run_id: row.run_id,
    repository_id: row.repository_id,
    origin: grant.get_name("origin"),
  }
}

///|
fn artifact_capability(
  tx : @database.DbTransaction,
  access : ArtifactAccess,
  artifact_id : Int64,
  operation : String,
  now : Int64,
) -> String raise {
  ignore(
    tx.execute("DELETE FROM pipeline_artifact_capability WHERE expires_ms<=?", params=[
      now,
    ]),
  )
  let count : Int64 = tx
    .query_one(
      "SELECT COUNT(*) AS count FROM pipeline_artifact_capability c JOIN pipeline_artifact_runtime r ON r.token_hash=c.runtime_hash WHERE r.attempt_id=?",
      params=[access.attempt_id],
    )
    .get_name("count")
  guard count < 4096L else {
    raise @domain.BadRequest(message="too many artifact capabilities")
  }
  let key = @identity.random_hex(32)
  ignore(
    tx.execute(
      "INSERT INTO pipeline_artifact_capability(token_hash,runtime_hash,artifact_id,operation,expires_ms) VALUES(?,?,?,?,?)",
      params=[
        @identity.hash_token(key),
        access.runtime_hash,
        artifact_id,
        operation,
        now + 600000L,
      ],
    ),
  )
  access.origin + "/-/artifact-blobs/" + artifact_id.to_string() + "?sig=" + key
}
