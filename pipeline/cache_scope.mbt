///|
let maximum_cache_bytes : Int64 = 536870912L

///|
fn snapshot_cache_scope(
  tx : @database.DbTransaction,
  run : Run,
  check : Int64,
  source~ : Int64 = 0L,
) -> Unit raise {
  if source != 0L {
    ignore(
      tx.execute(
        "INSERT INTO pipeline_cache_scope(run_id,scope,base_scope,default_scope) SELECT ?,scope,base_scope,default_scope FROM pipeline_cache_scope WHERE run_id=?",
        params=[run.id, source],
      ),
    )
    return
  }
  // Trust comes only from server-created immutable event and MR snapshots.
  guard run.context is Some(context) else { return }
  let default_branch : String = tx
    .query_one("SELECT default_branch FROM repository WHERE id=?", params=[
      run.repository_id,
    ])
    .get_name("default_branch")
  let default_scope = if default_branch == "HEAD" {
    ""
  } else {
    "refs/heads/" + default_branch
  }
  let (scope, base) = if check != 0L {
    let mr = tx.query_one(
      "SELECT merge_request_id FROM merge_check WHERE id=?",
      params=[check],
    )
    (
      "refs/pull/" +
      (mr.get_name("merge_request_id") : Int64).to_string() +
      "/merge",
      "refs/heads/" + context.base_ref,
    )
  } else {
    guard ["push", "workflow_dispatch"].contains(context.event_name) else {
      return
    }
    ("refs/heads/" + run.source_branch, "")
  }
  ignore(
    tx.execute(
      "INSERT INTO pipeline_cache_scope(run_id,scope,base_scope,default_scope) VALUES(?,?,?,?)",
      params=[run.id, scope, base, default_scope],
    ),
  )
}

///|
fn cache_scopes(
  tx : @database.DbTransaction,
  access : ArtifactAccess,
) -> Array[String] raise {
  let row = tx.query_opt("SELECT * FROM pipeline_cache_scope WHERE run_id=?", params=[
    access.run_id,
  ])
  guard row is Some(row) else {
    raise @domain.Forbidden(message="cache requires a captured run scope")
  }
  let result : Array[String] = []
  for name in ["scope", "base_scope", "default_scope"] {
    let value : String = row.get_name(name)
    if !value.is_empty() && !result.contains(value) {
      result.push(value)
    }
  }
  result
}

///|
fn check_cache_bytes(
  tx : @database.DbTransaction,
  repository : Int64,
  extra : Int64,
) -> Unit raise {
  let used : Int64 = tx
    .query_one(
      "SELECT COALESCE(SUM(b.size),0) AS size FROM pipeline_artifact_block b JOIN pipeline_artifact a ON a.id=b.artifact_id WHERE a.repository_id=? AND a.kind='cache'",
      params=[repository],
    )
    .get_name("size")
  guard used + extra <= 10737418240L else {
    raise @domain.BadRequest(
      message="cache storage quota exceeded; cleanup required",
    )
  }
}

///|
async fn Coordinator::make_cache_space(
  self : Coordinator,
  root : String,
  id : Int64,
  sig : String,
  block : String,
  size : Int64,
) -> Unit {
  let evicted = self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = artifact_blob_access(tx, id, sig, "write", (self.clock)())
        if (row.get_name("kind") : String) != "cache" {
          return false
        }
        if (row.get_name("state") : String) != "pending" {
          return false
        }
        let own : Int64 = tx
          .query_one(
            "SELECT COALESCE(SUM(size),0) AS size FROM pipeline_artifact_block WHERE artifact_id=? AND block_id <> ?",
            params=[id, block],
          )
          .get_name("size")
        guard own + size <= maximum_cache_bytes else {
          raise @domain.BadRequest(message="cache archive byte quota exceeded")
        }
        let repository : Int64 = row.get_name("repository_id")
        let used : Int64 = tx
          .query_one(
            "SELECT COALESCE(SUM(b.size),0) AS size FROM pipeline_artifact_block b JOIN pipeline_artifact a ON a.id=b.artifact_id WHERE a.repository_id=? AND a.kind='cache'",
            params=[repository],
          )
          .get_name("size")
        let previous : Int64 = tx
          .query_one(
            "SELECT COALESCE(SUM(size),0) AS size FROM pipeline_artifact_block WHERE artifact_id=? AND block_id=?",
            params=[id, block],
          )
          .get_name("size")
        if used + size - previous <= 10737418240L {
          return false
        }
        let rows = tx.query_all(
          "SELECT c.artifact_id,COALESCE(SUM(b.size),0) AS size FROM pipeline_cache c JOIN pipeline_artifact a ON a.id=c.artifact_id LEFT JOIN pipeline_artifact_block b ON b.artifact_id=a.id WHERE c.repository_id=? AND c.state='ready' AND c.artifact_id <> ? GROUP BY c.artifact_id ORDER BY c.last_access_ms,c.artifact_id LIMIT 100",
          params=[repository, id],
        )
        let mut freed = 0L
        for victim in rows {
          let cache_id : Int64 = victim.get_name("artifact_id")
          ignore(
            tx.execute(
              "UPDATE pipeline_cache SET state='deleted' WHERE artifact_id=?",
              params=[cache_id],
            ),
          )
          ignore(
            tx.execute(
              "UPDATE pipeline_artifact SET state='deleted' WHERE id=?",
              params=[cache_id],
            ),
          )
          freed += (victim.get_name("size") : Int64)
          if used + size - previous - freed <= 10737418240L {
            break
          }
        }
        true
      },
      immediate=true,
    )
  })
  // Commit tombstones before reclaiming files; never roll eviction back merely
  // because capacity remains exhausted by concurrent uploads.
  if evicted {
    self.cleanup_artifacts(root)
  }
}
