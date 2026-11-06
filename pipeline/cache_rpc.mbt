///|
fn cache_string(
  fields : Map[String, Json],
  name : String,
  maximum : Int32,
) -> String raise {
  let value = artifact_string(fields, name)
  guard !value.is_empty() &&
    @utf8.encode(value).length() <= maximum &&
    value.iter().all(ch => ch.to_int() >= 32 && ch.to_int() != 127) &&
    !value.contains(",") else {
    raise @domain.BadRequest(message="invalid cache " + name)
  }
  value
}

///|
pub fn Coordinator::cache_rpc(
  self : Coordinator,
  token : String,
  operation : String,
  payload : Json,
) -> Json raise {
  guard token.length() <= 4096 && payload is Object(fields) else {
    raise @domain.BadRequest(message="invalid cache RPC")
  }
  // Metadata supplied by downloaded code never selects an authorization scope.
  for name, _ in fields {
    guard ["key", "version", "size_bytes", "restore_keys", "metadata"].contains(
      name,
    ) else {
      raise @domain.BadRequest(message="unknown cache field")
    }
  }
  let key = cache_string(fields, "key", 512)
  let version = cache_string(fields, "version", 256)
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let now = (self.clock)()
        let access = artifact_access(tx, @identity.hash_token(token), now)
        let scopes = cache_scopes(tx, access)
        ignore(
          tx.execute(
            "UPDATE pipeline_cache SET state='deleted' WHERE repository_id=? AND artifact_id IN (SELECT id FROM pipeline_artifact WHERE repository_id=? AND (state='deleted' OR expires_ms<=?))",
            params=[access.repository_id, access.repository_id, now],
          ),
        )
        ignore(
          tx.execute(
            "UPDATE pipeline_artifact SET state='deleted' WHERE repository_id=? AND kind='cache' AND id IN (SELECT artifact_id FROM pipeline_cache WHERE repository_id=? AND state='deleted')",
            params=[access.repository_id, access.repository_id],
          ),
        )
        match operation {
          "CreateCacheEntry" => {
            let existing = tx.query_opt(
              "SELECT a.id,a.attempt_id,a.state FROM pipeline_cache c JOIN pipeline_artifact a ON a.id=c.artifact_id WHERE c.repository_id=? AND c.scope=? AND c.key=? AND c.version=? AND c.state <> 'deleted'",
              params=[access.repository_id, scopes[0], key, version],
            )
            if existing is Some(row) {
              if ["pending", "uploaded"].contains(
                  (row.get_name("state") : String),
                ) &&
                (row.get_name("attempt_id") : Int64) == access.attempt_id {
                return {
                  "ok": true,
                  "signed_upload_url": artifact_capability(
                    tx,
                    access,
                    row.get_name("id"),
                    "write",
                    now,
                  ),
                }
              }
              return {
                "ok": false,
                "message": "cache already exists or is reserved",
              }
            }
            let count : Int64 = tx
              .query_one(
                "SELECT COUNT(*) AS count FROM pipeline_cache WHERE repository_id=?",
                params=[access.repository_id],
              )
              .get_name("count")
            guard count < 1100L else {
              raise @domain.BadRequest(
                message="cache entry quota exceeded; cleanup pending",
              )
            }
            let active : Int64 = tx
              .query_one(
                "SELECT COUNT(*) AS count FROM pipeline_cache WHERE repository_id=? AND state <> 'deleted'",
                params=[access.repository_id],
              )
              .get_name("count")
            if active >= 1000L {
              let victim = tx.query_opt(
                "SELECT artifact_id FROM pipeline_cache WHERE repository_id=? AND state='ready' ORDER BY last_access_ms,artifact_id LIMIT 1",
                params=[access.repository_id],
              )
              guard victim is Some(victim) else {
                raise @domain.BadRequest(message="cache entry quota exceeded")
              }
              let id : Int64 = victim.get_name("artifact_id")
              ignore(
                tx.execute(
                  "UPDATE pipeline_cache SET state='deleted' WHERE artifact_id=?",
                  params=[id],
                ),
              )
              ignore(
                tx.execute(
                  "UPDATE pipeline_artifact SET state='deleted' WHERE id=?",
                  params=[id],
                ),
              )
            }
            let pending : Int64 = tx
              .query_one(
                "SELECT COUNT(*) AS count FROM pipeline_cache WHERE repository_id=? AND state='pending'",
                params=[access.repository_id],
              )
              .get_name("count")
            guard pending < 100L else {
              raise @domain.BadRequest(message="too many cache reservations")
            }
            let id : Int64 = tx
              .query_one(
                "INSERT INTO pipeline_artifact(repository_id,run_id,attempt_id,name,storage_key,state,kind,created_ms,expires_ms) VALUES(?,?,?,?,?,'pending','cache',?,?) RETURNING id",
                params=[
                  access.repository_id,
                  access.run_id,
                  access.attempt_id,
                  @identity.random_hex(32),
                  @identity.random_hex(32),
                  now,
                  now + 3600000L,
                ],
              )
              .get_name("id")
            ignore(
              tx.execute(
                "INSERT INTO pipeline_cache(artifact_id,repository_id,scope,key,version,state,created_ms,last_access_ms) VALUES(?,?,?,?,?,'pending',?,?)",
                params=[
                  id,
                  access.repository_id,
                  scopes[0],
                  key,
                  version,
                  now,
                  now,
                ],
              ),
            )
            {
              "ok": true,
              "signed_upload_url": artifact_capability(
                tx, access, id, "write", now,
              ),
            }
          }
          "FinalizeCacheEntryUpload" => {
            let size = artifact_string(fields, "size_bytes")
            let row = tx.query_opt(
              "SELECT a.* FROM pipeline_cache c JOIN pipeline_artifact a ON a.id=c.artifact_id WHERE c.repository_id=? AND c.scope=? AND c.key=? AND c.version=? AND c.state <> 'deleted' AND a.attempt_id=? AND a.expires_ms>?",
              params=[
                access.repository_id,
                scopes[0],
                key,
                version,
                access.attempt_id,
                now,
              ],
            )
            guard row is Some(row) &&
              ["uploaded", "ready"].contains((row.get_name("state") : String)) &&
              size == (row.get_name("size") : Int64).to_string() else {
              raise @domain.BadRequest(
                message="cache upload incomplete or size mismatch",
              )
            }
            let id : Int64 = row.get_name("id")
            ignore(
              tx.execute(
                "UPDATE pipeline_artifact SET state='ready',expires_ms=? WHERE id=?",
                params=[now + 604800000L, id],
              ),
            )
            ignore(
              tx.execute(
                "UPDATE pipeline_cache SET state='ready',last_access_ms=? WHERE artifact_id=?",
                params=[now, id],
              ),
            )
            { "ok": true, "entry_id": id.to_string() }
          }
          "GetCacheEntryDownloadURL" => {
            let keys = [key]
            match fields.get("restore_keys") {
              Some(Array(values)) => {
                guard values.length() <= 9 else {
                  raise @domain.BadRequest(message="at most ten cache keys")
                }
                for value in values {
                  guard value is String(value) else {
                    raise @domain.BadRequest(message="invalid restore key")
                  }
                  keys.push(
                    cache_string({ "key": Json::string(value) }, "key", 512),
                  )
                }
              }
              None => ()
              _ => raise @domain.BadRequest(message="invalid restore keys")
            }
            for scope in scopes {
              for lookup in keys {
                let row = tx.query_opt(
                  "SELECT a.id,c.key FROM pipeline_cache c JOIN pipeline_artifact a ON a.id=c.artifact_id WHERE c.repository_id=? AND c.scope=? AND c.version=? AND c.state='ready' AND a.state='ready' AND a.expires_ms>? AND substr(c.key,1,length(?))=? ORDER BY CASE WHEN c.key=? THEN 0 ELSE 1 END,c.created_ms DESC,a.id DESC LIMIT 1",
                  params=[
                    access.repository_id,
                    scope,
                    version,
                    now,
                    lookup,
                    lookup,
                    lookup,
                  ],
                )
                if row is Some(row) {
                  let id : Int64 = row.get_name("id")
                  ignore(
                    tx.execute(
                      "UPDATE pipeline_cache SET last_access_ms=? WHERE artifact_id=?",
                      params=[now, id],
                    ),
                  )
                  ignore(
                    tx.execute(
                      "UPDATE pipeline_artifact SET expires_ms=? WHERE id=?",
                      params=[now + 604800000L, id],
                    ),
                  )
                  return {
                    "ok": true,
                    "matched_key": (row.get_name("key") : String),
                    "signed_download_url": artifact_capability(
                      tx, access, id, "read", now,
                    ),
                  }
                }
              }
            }
            { "ok": false }
          }
          _ => raise @domain.NotFound(message="unknown cache operation")
        }
      },
      immediate=true,
    )
  })
}
