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
  if !body.is_empty() {
    let id : Int64 = tx
      .query_one("SELECT last_insert_rowid() AS id")
      .get_name("id")
    @attachments.replace_references(
      tx,
      mr.repository_id,
      actor,
      MergeComment(id),
      body,
    )
  }
}

///|
pub struct MergeActivity {
  id : Int64
  actor_id : Int64?
  actor : String
  kind : String
  body : String
  created_at : String
  version : Int64
  discussion_id : Int64?
}

///|
pub fn list_merge_requests(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  status : String,
  page : Int64,
  query~ : String = "",
  author~ : Int64 = 0L,
  reviewer~ : Int64 = 0L,
) -> Array[MergeRequest] raise {
  guard page > 0L && page <= 100000L && query.length() <= 200 else {
    raise @domain.BadRequest(message="invalid merge request filter")
  }
  pool.with_client(client => {
    client
    .query_all(
      "\{merge_request_select} WHERE m.repository_id = ? AND m.status = ? AND instr(lower(m.title), lower(?)) > 0 AND (? = 0 OR m.author_id = ?) AND (? = 0 OR EXISTS (SELECT 1 FROM merge_review_request q WHERE q.merge_request_id = m.id AND q.user_id = ? AND q.pending = 1)) ORDER BY m.number DESC LIMIT 51 OFFSET ?",
      params=[
        scope.id,
        status,
        query,
        author,
        author,
        reviewer,
        reviewer,
        (page - 1L) * 50L,
      ],
    )
    .map(MergeRequest::from_row)
  })
}

///|
pub struct MergeListMeta {
  approvals : Int64
  requested : Int64
  checks : String
  updated : String
}

///|
pub fn merge_list_metadata(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  rows : Array[MergeRequest],
) -> Map[Int64, MergeListMeta] raise {
  if rows.is_empty() {
    return Map([])
  }
  let ids = rows.map(row => row.id.to_string()).join(",")
  pool.with_client(client => {
    let result : Map[Int64, MergeListMeta] = Map([])
    for
      row in client.query_all(
        "SELECT m.id, m.updated_at, (SELECT COUNT(*) FROM merge_review v JOIN collaboration_access a ON a.repository_id = m.repository_id AND a.user_id = v.user_id AND a.contributor = 1 WHERE v.merge_request_id = m.id AND v.version = m.current_version AND v.user_id <> m.author_id AND v.decision = 'approved') AS approvals, (SELECT COUNT(*) FROM merge_review_request q JOIN collaboration_access a ON a.repository_id = m.repository_id AND a.user_id = q.user_id AND a.contributor = 1 WHERE q.merge_request_id = m.id AND q.pending = 1) AS requested, CASE WHEN EXISTS (SELECT 1 FROM merge_check c WHERE c.merge_request_id = m.id AND c.version = m.current_version AND c.generation = m.check_generation AND (c.state = 'error' OR c.conclusion IN ('failure','timed_out','lost','cancelled'))) THEN 'failure' WHEN EXISTS (SELECT 1 FROM merge_check c WHERE c.merge_request_id = m.id AND c.version = m.current_version AND c.generation = m.check_generation AND c.state <> 'completed') THEN 'pending' WHEN EXISTS (SELECT 1 FROM merge_check c WHERE c.merge_request_id = m.id AND c.version = m.current_version AND c.generation = m.check_generation) THEN 'success' ELSE '' END AS checks FROM merge_request m WHERE m.repository_id = ? AND m.id IN (\{ids})",
        params=[scope.id],
      ) {
      result.set(row.get_name("id"), {
        approvals: row.get_name("approvals"),
        requested: row.get_name("requested"),
        checks: row.get_name("checks"),
        updated: row.get_name("updated_at"),
      })
    }
    result
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
      id: row.get_name("id"),
      actor_id: row.get_name("actor_id"),
      actor: row.get_name("actor"),
      kind: row.get_name("kind"),
      body: if (row.get_name("kind") : String) == "comment_deleted" {
        ""
      } else {
        row.get_name("body")
      },
      created_at: row.get_name("created_at"),
      version: row.get_name("version"),
      discussion_id: row.get_name("discussion_id"),
    })
  })
}
