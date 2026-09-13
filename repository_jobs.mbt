///|
struct TeamRepository {
  name : String
  visibility : String
  ready : Bool
  status : String?
}

///|
struct RepositoryJob {
  id : Int64
  team_id : Int64
  repo : RepoId
  requester_id : Int64
  source_url : String
  status : String
  stage_token : String
  last_error : String?
  attempt_count : Int64
  source_kind : String
  source_repository_id : Int64?
}

///|
let repository_job_select : String =
  #|SELECT r.id, r.team_id, t.name_key AS owner, r.name,
  #|  j.requested_by_user_id, j.source_url, j.status, j.stage_token,
  #|  j.last_error, j.attempt_count, j.source_kind, j.source_repository_id
  #|FROM repository_job AS j
  #|JOIN repository AS r ON r.id = j.repository_id
  #|JOIN team AS t ON t.id = r.team_id

///|
fn RepositoryJob::from_row(row : DbRow) -> RepositoryJob raise {
  {
    id: row.get_name("id"),
    team_id: row.get_name("team_id"),
    repo: { owner: row.get_name("owner"), name: row.get_name("name"), },
    requester_id: row.get_name("requested_by_user_id"),
    source_url: row.get_name("source_url"),
    status: row.get_name("status"),
    stage_token: row.get_name("stage_token"),
    last_error: row.get_name("last_error"),
    attempt_count: row.get_name("attempt_count"),
    source_kind: row.get_name("source_kind"),
    source_repository_id: row.get_name("source_repository_id"),
  }
}

///|
fn team_repositories(
  pool : Database,
  team : TeamSummary,
) -> Array[TeamRepository] raise {
  pool.with_client(client => {
    client
    .query_all(
      (
        #|SELECT r.name, r.visibility, r.ready,
        #|  CASE WHEN j.status = 'running' AND j.source_url = '' THEN 'creating' ELSE j.status END AS status
        #|FROM repository AS r LEFT JOIN repository_job AS j ON j.repository_id = r.id
        #|WHERE r.team_id = ? ORDER BY r.name
      ),
      params=[team.id],
    )
    .map(row => {
      name: row.get_name("name"),
      visibility: row.get_name("visibility"),
      ready: row.get_name("ready"),
      status: row.get_name("status"),
    })
  })
}

///|
fn require_repository_job(
  pool : Database,
  team : TeamSummary,
  name : String,
) -> RepositoryJob raise {
  pool.with_client(client => {
    let row = client.query_opt(
      "\{repository_job_select} WHERE r.team_id = ? AND r.name = ?",
      params=[team.id, name],
    )
    guard row is Some(row) else {
      raise NotFound(message="repository operation not found")
    }
    RepositoryJob::from_row(row)
  })
}

///|
fn require_repository_manager(
  pool : Database,
  actor : CurrentUser,
  team : TeamSummary,
) -> Unit raise {
  require_team_member_access(pool, actor, team)
  guard can_manage_team(pool, actor, team.id) else {
    raise Forbidden(message="team owner or admin required")
  }
}

///|
async fn enqueue_repository(
  pool : Database,
  root : String,
  actor : CurrentUser,
  team : TeamSummary,
  name : String,
  visibility : String,
  source_url : String,
  addresses? : SshAddressConfig = no_ssh_address_config,
) -> RepoId {
  require_repository_manager(pool, actor, team)
  let repo = parse_transport_repo("\{team.name_key}/\{name}")
  let source = if source_url.is_empty() {
    None
  } else {
    Some(resolve_repository_import_source(pool, actor, source_url, addresses))
  }
  let source_url = source.map(value => value.submitted_url).unwrap_or("")
  guard visibility == "private" || visibility == "public" else {
    raise BadRequest(message="visibility must be public or private")
  }
  guard !@fs.exists(repo.git_dir(root)) else {
    raise BadRequest(message="repository directory already exists")
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      let row = tx.query_opt(
        (
          #|INSERT INTO repository (team_id, name, visibility, ready)
          #|VALUES (?, ?, ?, 0) ON CONFLICT (team_id, name) DO NOTHING RETURNING id
        ),
        params=[team.id, repo.name, visibility],
      )
      guard row is Some(row) else {
        raise BadRequest(message="repository name is already taken")
      }
      let id : Int64 = row.get_name("id")
      match source {
        Some({ local_id: Some(source_id), .. }) => {
          let _ = tx.execute(
            "INSERT INTO repository_job (repository_id, requested_by_user_id, source_url, source_kind, source_repository_id) VALUES (?, ?, ?, 'local', ?)",
            params=[id, actor.id, source_url, source_id],
          )
        }
        _ => {
          let _ = tx.execute(
            "INSERT INTO repository_job (repository_id, requested_by_user_id, source_url, source_kind) VALUES (?, ?, ?, 'external')",
            params=[id, actor.id, source_url],
          )
        }
      }
    })
  })
  repo
}

///|
fn retry_repository_job(
  pool : Database,
  actor : CurrentUser,
  team : TeamSummary,
  name : String,
) -> Unit raise {
  require_repository_manager(pool, actor, team)
  let changed = pool.with_client(client => {
    client.execute(
      (
        #|UPDATE repository_job SET status = 'pending', last_error = NULL,
        #|  requested_by_user_id = ?, updated_at = datetime('now')
        #|WHERE status = 'failed' AND repository_id IN
        #|  (SELECT id FROM repository WHERE team_id = ? AND name = ? AND ready = 0)
      ),
      params=[actor.id, team.id, name],
    )
  })
  guard changed == 1 else {
    raise NotFound(message="failed repository operation not found")
  }
}

///|
async fn discard_repository_job(
  pool : Database,
  root : String,
  actor : CurrentUser,
  team : TeamSummary,
  name : String,
) -> Unit {
  require_repository_manager(pool, actor, team)
  let job = require_repository_job(pool, team, name)
  guard job.status == "failed" else {
    raise BadRequest(message="only failed operations can be discarded")
  }
  guard !@fs.exists(job.repo.git_dir(root)) else {
    raise BadRequest(
      message="repository data exists; ask an operator to inspect it before discarding",
    )
  }
  let changed = pool.with_client(client => {
    client.execute(
      (
        #|DELETE FROM repository WHERE id = ? AND ready = 0 AND id IN
        #|  (SELECT repository_id FROM repository_job WHERE status = 'failed')
      ),
      params=[job.id],
    )
  })
  guard changed == 1 else {
    raise NotFound(message="failed repository operation not found")
  }
}
