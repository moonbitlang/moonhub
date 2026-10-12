///|
pub struct MergeRequest {
  id : Int64
  repository_id : Int64
  number : Int64
  author_id : Int64
  author : String
  title : String
  description : String
  source : String
  target : String
  draft : Bool
  status : String
  version : Int64
  merged_sha : String
  job_status : String
  job_error : String
  issue_number : Int64
  edit_version : Int64
}

///|
let merge_request_select : String =
  #|SELECT m.*, u.display_name AS author,
  #|  COALESCE(m.merged_sha, '') AS merged_commit,
  #|  COALESCE(j.status, '') AS job_status, COALESCE(j.last_error, '') AS job_error,
  #|  COALESCE((SELECT number FROM issue WHERE id = m.issue_id), 0) AS issue_number
  #|FROM merge_request AS m JOIN "user" AS u ON u.id = m.author_id
  #|LEFT JOIN merge_job AS j ON j.merge_request_id = m.id

///|
fn MergeRequest::from_row(row : @database.DbRow) -> MergeRequest raise {
  {
    id: row.get_name("id"),
    repository_id: row.get_name("repository_id"),
    number: row.get_name("number"),
    author_id: row.get_name("author_id"),
    author: row.get_name("author"),
    title: row.get_name("title"),
    description: row.get_name("description"),
    source: row.get_name("source_branch"),
    target: row.get_name("target_branch"),
    draft: row.get_name("draft"),
    status: row.get_name("status"),
    version: row.get_name("current_version"),
    merged_sha: row.get_name("merged_commit"),
    job_status: row.get_name("job_status"),
    job_error: row.get_name("job_error"),
    issue_number: row.get_name("issue_number"),
    edit_version: row.get_name("edit_version"),
  }
}

///|
pub fn require_merge_request(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  number : Int64,
) -> MergeRequest raise {
  pool.with_client(client => {
    let row = client.query_opt(
      "\{merge_request_select} WHERE m.repository_id = ? AND m.number = ?",
      params=[scope.id, number],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="merge request not found")
    }
    MergeRequest::from_row(row)
  })
}

///|
pub fn merge_revision(
  pool : @database.Database,
  mr : MergeRequest,
  version? : Int64,
) -> MergeRevision raise {
  pool.with_client(client => {
    let row = client.query_opt(
      "SELECT * FROM merge_revision WHERE merge_request_id = ? AND version = ?",
      params=[mr.id, version.unwrap_or(mr.version)],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="merge request version not found")
    }
    {
      version: row.get_name("version"),
      source_sha: row.get_name("source_sha"),
      target_sha: row.get_name("target_sha"),
      base_sha: row.get_name("base_sha"),
      merge_tree: row.get_name("merge_tree"),
      block_reason: @domain.public_merge_block_reason(
        row.get_name("block_reason"),
      ),
    }
  })
}

///|
fn merge_activity(
  tx : @database.DbTransaction,
  mr : MergeRequest,
  actor : Int64,
  kind : String,
  body~ : String = "",
) -> Unit raise {
  let _ = tx.execute(
    "INSERT INTO merge_activity (merge_request_id, actor_id, kind, body, version) VALUES (?, NULLIF(?, 0), ?, ?, ?)",
    params=[mr.id, actor, kind, body, mr.version],
  )
}

///|
pub struct MergeActivity {
  actor : String
  kind : String
  body : String
  created_at : String
  version : Int64
}

///|
pub fn list_merge_requests(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  status : String,
  page : Int64,
) -> Array[MergeRequest] raise {
  pool.with_client(client => {
    client
    .query_all(
      "\{merge_request_select} WHERE m.repository_id = ? AND m.status = ? ORDER BY m.number DESC LIMIT 51 OFFSET ?",
      params=[scope.id, status, (page - 1L) * 50L],
    )
    .map(MergeRequest::from_row)
  })
}

///|
pub fn issue_merge_requests(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  issue : Issue,
) -> Array[MergeRequest] raise {
  pool.with_client(client => {
    client
    .query_all(
      "\{merge_request_select} WHERE m.repository_id = ? AND m.issue_id = ? ORDER BY m.number DESC LIMIT 50",
      params=[scope.id, issue.id],
    )
    .map(MergeRequest::from_row)
  })
}

///|
pub fn list_merge_activity(
  pool : @database.Database,
  mr : MergeRequest,
  page : Int64,
) -> Array[MergeActivity] raise {
  pool.with_client(client => {
    client
    .query_all(
      "SELECT a.*, COALESCE(u.display_name, 'Moonhub') AS actor FROM merge_activity AS a LEFT JOIN \"user\" AS u ON u.id = a.actor_id WHERE a.merge_request_id = ? ORDER BY a.id DESC LIMIT 51 OFFSET ?",
      params=[mr.id, (page - 1L) * 50L],
    )
    .map(row => {
      actor: row.get_name("actor"),
      kind: row.get_name("kind"),
      body: row.get_name("body"),
      created_at: row.get_name("created_at"),
      version: row.get_name("version"),
    })
  })
}
