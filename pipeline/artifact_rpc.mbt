///|
pub let maximum_artifact_bytes : Int64 = 536870912L

///|
pub let maximum_artifact_block_bytes : Int32 = 8388608

///|
fn artifact_string(fields : Map[String, Json], key : String) -> String raise {
  guard fields.get(key) is Some(String(value)) else {
    raise @domain.BadRequest(message="missing artifact field: " + key)
  }
  value
}

///|
fn artifact_name(fields : Map[String, Json]) -> String raise {
  let name = artifact_string(fields, "name")
  guard !name.trim().is_empty() &&
    @utf8.encode(name).length() <= 256 &&
    name
    .iter()
    .all(ch => {
      ch.to_int() >= 32 &&
      ch.to_int() != 127 &&
      !['/', '\\', ':', '*', '?', '"', '<', '>', '|'].contains(ch)
    }) else {
    raise @domain.BadRequest(message="invalid artifact name")
  }
  name
}

///|
fn artifact_wire_row(row : @database.DbRow) -> Json raise {
  {
    "workflow_run_backend_id": (row.get_name("run_id") : Int64).to_string(),
    "workflow_job_run_backend_id": (row.get_name("attempt_id") : Int64).to_string(),
    "database_id": (row.get_name("id") : Int64).to_string(),
    "name": (row.get_name("name") : String),
    "size": (row.get_name("size") : Int64).to_string(),
    "digest": (row.get_name("digest") : String),
    "created_at": (row.get_name("created_iso") : String),
  }
}

///|
pub fn Coordinator::artifact_rpc(
  self : Coordinator,
  token : String,
  operation : String,
  payload : Json,
) -> Json raise {
  guard token.length() <= 4096 && payload is Object(fields) else {
    raise @domain.BadRequest(message="invalid artifact RPC")
  }
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let now = (self.clock)()
        let access = artifact_access(tx, @identity.hash_token(token), now)
        guard artifact_string(fields, "workflow_run_backend_id") ==
          access.run_id.to_string() else {
          raise @domain.Forbidden(message="artifact run scope mismatch")
        }
        let requested_job = artifact_string(
          fields, "workflow_job_run_backend_id",
        )
        // Read/delete requests made after listing refer to the artifact's producer.
        // Scope remains the current runtime's run; producer IDs do not grant access.
        if ["CreateArtifact", "FinalizeArtifact", "ListArtifacts"].contains(
            operation,
          ) {
          guard requested_job == access.attempt_id.to_string() else {
            raise @domain.Forbidden(message="artifact job scope mismatch")
          }
        }
        match operation {
          "CreateArtifact" => {
            let name = artifact_name(fields)
            guard fields.get("version") is Some(Number(4, ..)) else {
              raise @domain.BadRequest(
                message="only artifact protocol version 4 is supported",
              )
            }
            let expires = match fields.get("expires_at") {
              None => now + 604800000L
              Some(String(text)) => {
                guard text.length() <= 40 else {
                  raise @domain.BadRequest(message="invalid artifact expiry")
                }
                let value : Int64? = tx
                  .query_one(
                    "SELECT CAST(strftime('%s',?) AS INTEGER)*1000 AS expiry",
                    params=[text],
                  )
                  .get_name("expiry")
                guard value is Some(value) &&
                  value > now &&
                  value <= now + 7776000000L else {
                  raise @domain.BadRequest(
                    message="retention must be within 90 days",
                  )
                }
                value
              }
              _ => raise @domain.BadRequest(message="invalid artifact expiry")
            }
            ignore(
              tx.execute(
                "UPDATE pipeline_artifact SET state='deleted' WHERE run_id=? AND expires_ms<=?",
                params=[access.run_id, now],
              ),
            )
            guard tx.query_opt(
                "SELECT id FROM pipeline_artifact WHERE kind='artifact' AND run_id=? AND name=? AND state <> 'deleted'",
                params=[access.run_id, name],
              )
              is None else {
              raise Conflict("artifact name already exists; use overwrite")
            }
            let count : Int64 = tx
              .query_one(
                "SELECT COUNT(*) AS count FROM pipeline_artifact WHERE kind='artifact' AND run_id=?",
                params=[access.run_id],
              )
              .get_name("count")
            guard count < 500L else {
              raise @domain.BadRequest(message="artifact count quota exceeded")
            }
            let id : Int64 = tx
              .query_one(
                "INSERT INTO pipeline_artifact(repository_id,run_id,attempt_id,name,storage_key,state,created_ms,expires_ms) VALUES(?,?,?,?,?,'pending',?,?) RETURNING id",
                params=[
                  access.repository_id,
                  access.run_id,
                  access.attempt_id,
                  name,
                  @identity.random_hex(32),
                  now,
                  expires,
                ],
              )
              .get_name("id")
            {
              "ok": true,
              "signed_upload_url": artifact_capability(
                tx, access, id, "write", now,
              ),
            }
          }
          "ListArtifacts" => {
            let rows = tx.query_all(
              "SELECT *,strftime('%Y-%m-%dT%H:%M:%fZ',created_ms/1000.0,'unixepoch') AS created_iso FROM pipeline_artifact WHERE kind='artifact' AND run_id=? AND state='ready' AND expires_ms>? ORDER BY id",
              params=[access.run_id, now],
            )
            let name = match fields.get("name_filter") {
              None => None
              Some(String(value)) => Some(value)
              _ => raise @domain.BadRequest(message="invalid name filter")
            }
            let id = match fields.get("id_filter") {
              None => None
              Some(String(value)) => Some(value)
              _ => raise @domain.BadRequest(message="invalid id filter")
            }
            {
              "artifacts": rows
              .filter(row => {
                (name is None || name == Some((row.get_name("name") : String))) &&
                (
                  id is None ||
                  id == Some((row.get_name("id") : Int64).to_string())
                )
              })
              .map(row => artifact_wire_row(row)),
            }
          }
          "FinalizeArtifact" => {
            let name = artifact_name(fields)
            let size = artifact_string(fields, "size")
            let hash = artifact_string(fields, "hash")
            let row = tx.query_opt(
              "SELECT * FROM pipeline_artifact WHERE kind='artifact' AND run_id=? AND attempt_id=? AND name=? AND state IN ('uploaded','ready') AND expires_ms>?",
              params=[access.run_id, access.attempt_id, name, now],
            )
            guard row is Some(row) &&
              size == (row.get_name("size") : Int64).to_string() &&
              hash == (row.get_name("digest") : String) else {
              raise @domain.BadRequest(
                message="artifact upload is incomplete or digest/size mismatch",
              )
            }
            let id : Int64 = row.get_name("id")
            ignore(
              tx.execute(
                "UPDATE pipeline_artifact SET state='ready' WHERE id=? AND state='uploaded'",
                params=[id],
              ),
            )
            { "ok": true, "artifact_id": id.to_string() }
          }
          "GetSignedArtifactURL" | "DeleteArtifact" => {
            let name = artifact_name(fields)
            let row = tx.query_opt(
              "SELECT * FROM pipeline_artifact WHERE kind='artifact' AND run_id=? AND name=? AND state='ready' AND expires_ms>?",
              params=[access.run_id, name, now],
            )
            guard row is Some(row) &&
              requested_job == (row.get_name("attempt_id") : Int64).to_string() else {
              raise @domain.NotFound(message="artifact not found")
            }
            let id : Int64 = row.get_name("id")
            if operation == "DeleteArtifact" {
              ignore(
                tx.execute(
                  "UPDATE pipeline_artifact SET state='deleted' WHERE id=?",
                  params=[id],
                ),
              )
              { "ok": true, "artifact_id": id.to_string() }
            } else {
              { "signed_url": artifact_capability(tx, access, id, "read", now) }
            }
          }
          _ => raise @domain.NotFound(message="unknown artifact operation")
        }
      },
      immediate=true,
    )
  })
}
