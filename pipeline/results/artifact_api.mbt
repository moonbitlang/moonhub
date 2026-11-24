///|
fn artifact_api_json(row : @database.DbRow, base : String) -> Json raise {
  let id : Int64 = row.get_name("id")
  let url = base + "/actions/artifacts/" + id.to_string()
  {
    "id": id.to_double(),
    "name": (row.get_name("name") : String),
    "size_in_bytes": (row.get_name("size") : Int64).to_double(),
    "expired": false,
    "digest": (row.get_name("digest") : String),
    "url": url,
    "archive_download_url": url + "/zip",
    "created_at": (row.get_name("created_iso") : String),
    "updated_at": (row.get_name("created_iso") : String),
    "expires_at": (row.get_name("expires_iso") : String),
    "workflow_run": {
      "id": (row.get_name("public_id") : Int64).to_double(),
      "head_sha": (row.get_name("commit_sha") : String),
    },
  }
}

///|
pub fn Service::list_run_artifacts(
  self : Service,
  coordinator : @runtime.Coordinator,
  token : String,
  repo : @domain.RepoId,
  public_run : Int64,
  base : String,
  name~ : String = "",
  page~ : Int64 = 1L,
  per_page~ : Int64 = 30L,
) -> Json raise {
  let actor = coordinator.authenticate_job_api(token, repo, "actions:read")
  let scope = @repository.repository_scope(self.pool, actor, repo)
  @repository.authorize_repository(self.pool, actor, repo, Read)
  guard public_run > 0L &&
    name.length() <= 255 &&
    page >= 1L &&
    page <= 10000L &&
    per_page >= 1L &&
    per_page <= 100L else {
    raise @domain.BadRequest(message="invalid artifact query")
  }
  self.pool.with_client(c => {
    let run = c.query_opt(
      "SELECT id FROM pipeline_run WHERE repository_id=? AND COALESCE(public_run_id,id)=? ORDER BY run_attempt DESC LIMIT 1",
      params=[scope.id, public_run],
    )
    guard run is Some(run) else {
      raise @domain.NotFound(message="workflow run not found")
    }
    let run_id : Int64 = run.get_name("id")
    let now = (self.clock)()
    let count : Int64 = c
      .query_one(
        "SELECT count(*) n FROM pipeline_artifact WHERE run_id=? AND kind='artifact' AND state='ready' AND expires_ms>? AND (?='' OR name=?)",
        params=[run_id, now, name, name],
      )
      .get_name("n")
    let items = c.query_all(
      "SELECT a.*,COALESCE(r.public_run_id,r.id) public_id,r.commit_sha,strftime('%Y-%m-%dT%H:%M:%fZ',a.created_ms/1000.0,'unixepoch') created_iso,strftime('%Y-%m-%dT%H:%M:%fZ',a.expires_ms/1000.0,'unixepoch') expires_iso FROM pipeline_artifact a JOIN pipeline_run r ON r.id=a.run_id WHERE a.run_id=? AND a.kind='artifact' AND a.state='ready' AND a.expires_ms>? AND (?='' OR a.name=?) ORDER BY a.id DESC LIMIT ? OFFSET ?",
      params=[run_id, now, name, name, per_page, (page - 1L) * per_page],
    )
    {
      "total_count": count.to_double(),
      "artifacts": items.map(row => artifact_api_json(row, base)),
    }
  })
}

///|
pub fn Service::artifact_api_download(
  self : Service,
  coordinator : @runtime.Coordinator,
  token : String,
  repo : @domain.RepoId,
  id : Int64,
) -> String raise {
  let (actor, attempt) = coordinator.job_api_access(token, repo, "actions:read")
  @repository.authorize_repository(self.pool, actor, repo, Read)
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        let now = (self.clock)()
        guard tx.query_opt(
            "SELECT id FROM pipeline_artifact WHERE id=? AND repository_id=? AND kind='artifact' AND state='ready' AND expires_ms>?",
            params=[id, attempt.repository_id, now],
          )
          is Some(_) else {
          raise @domain.NotFound(message="artifact not found")
        }
        ignore(
          tx.execute(
            "DELETE FROM pipeline_artifact_api_capability WHERE expires_ms<=?",
            params=[now],
          ),
        )
        let digest = @identity.hash_token(token)
        let count : Int64 = tx
          .query_one(
            "SELECT count(*) n FROM pipeline_artifact_api_capability c JOIN pipeline_api_runtime g ON g.token_hash=c.api_hash WHERE g.attempt_id=?",
            params=[attempt.id],
          )
          .get_name("n")
        guard count < 4096L else {
          raise @domain.BadRequest(
            message="artifact download grant limit exceeded",
          )
        }
        let capability = @identity.random_hex(32)
        ignore(
          tx.execute(
            "INSERT INTO pipeline_artifact_api_capability(token_hash,api_hash,artifact_id,expires_ms) VALUES(?,?,?,?)",
            params=[
              @identity.hash_token(capability),
              digest,
              id,
              Int64::min(now + 600000L, attempt.deadline_ms),
            ],
          ),
        )
        // Mask download URLs if an upstream action logs one.
        ignore(
          tx.execute(
            "INSERT OR IGNORE INTO pipeline_secret_delivery(attempt_id,step_id,env_name,value) VALUES(?,?,?,?)",
            params=[
              attempt.id,
              "@artifact-api",
              @identity.hash_token(capability),
              capability,
            ],
          ),
        )
        capability
      },
      immediate=true,
    )
  })
}

///|
pub fn Service::artifact_api_blob(
  self : Service,
  coordinator : @runtime.Coordinator,
  root : String,
  repo : @domain.RepoId,
  id : Int64,
  capability : String,
) -> ArtifactBlob raise {
  guard capability.length() == 64 else {
    raise @domain.Unauthorized(message="invalid artifact download grant")
  }
  let (digest, run_id) = self.pool.with_client(c => {
    let row = c.query_opt(
      "SELECT c.api_hash,a.run_id FROM pipeline_artifact_api_capability c JOIN pipeline_artifact a ON a.id=c.artifact_id WHERE c.token_hash=? AND c.artifact_id=? AND c.expires_ms>?",
      params=[@identity.hash_token(capability), id, (self.clock)()],
    )
    guard row is Some(row) else {
      raise @domain.Unauthorized(message="expired artifact download grant")
    }
    ((row.get_name("api_hash") : String), (row.get_name("run_id") : Int64))
  })
  let (actor, _) = coordinator.job_api_access_hash(digest, repo, "actions:read")
  self.user_artifact(root, actor, repo, run_id, id)
}
