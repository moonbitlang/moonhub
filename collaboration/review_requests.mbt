///|
pub struct ReviewRequest {
  user_id : Int64
  display_name : String
  version : Int64
  pending : Bool
}

///|
pub fn review_candidates(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  mr : MergeRequest,
) -> Array[IssueAssignee] raise {
  guard mr.repository_id == scope.id else {
    raise @domain.NotFound(message="merge request not found")
  }
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Read)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT u.id, u.display_name, u.name_key FROM \"user\" u JOIN collaboration_access a ON a.user_id = u.id AND a.repository_id = ? AND a.contributor = 1 WHERE u.id <> ? ORDER BY u.display_name, u.id LIMIT 1000",
      params=[scope.id, mr.author_id],
    )
    .map(row => {
      id: row.get_name("id"),
      display_name: row.get_name("display_name"),
      name_key: row.get_name("name_key"),
    })
  })
}

///|
pub fn review_requests(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  mr : MergeRequest,
) -> Array[ReviewRequest] raise {
  guard mr.repository_id == scope.id else {
    raise @domain.NotFound(message="merge request not found")
  }
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Read)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT q.*, u.display_name FROM merge_review_request q JOIN \"user\" u ON u.id = q.user_id JOIN collaboration_access a ON a.user_id = u.id AND a.repository_id = ? AND a.contributor = 1 WHERE q.merge_request_id = ? ORDER BY u.display_name, u.id",
      params=[scope.id, mr.id],
    )
    .map(row => {
      user_id: row.get_name("user_id"),
      display_name: row.get_name("display_name"),
      version: row.get_name("version"),
      pending: row.get_name("pending"),
    })
  })
}

///|
// The caller holds the repository write lock, as for every MR mutation.
pub fn request_merge_review(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  mr : MergeRequest,
  reviewer : Int64,
  version : Int64,
) -> Unit raise {
  guard mr.repository_id == scope.id else {
    raise @domain.NotFound(message="merge request not found")
  }
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  guard actor.id == mr.author_id ||
    @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(
      message="only the author or a team administrator may request reviews",
    )
  }
  require_mutable_merge(mr)
  guard mr.status == "open" && !mr.draft && mr.version == version else {
    raise @domain.BadRequest(
      message="reload the current ready merge request before requesting a review",
    )
  }
  guard reviewer != mr.author_id else {
    raise @domain.BadRequest(
      message="the author cannot review their own merge request",
    )
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      guard tx.query_opt(
          "SELECT m.id FROM merge_request m WHERE m.id = ? AND m.repository_id = ? AND m.current_version = ? AND m.status = 'open' AND m.draft = 0",
          params=[mr.id, scope.id, version],
        )
        is Some(_) else {
        raise @domain.BadRequest(
          message="merge request changed; reload before requesting a review",
        )
      }
      guard tx.query_opt(
          "SELECT user_id FROM collaboration_access WHERE user_id = ? AND repository_id = ? AND contributor = 1",
          params=[reviewer, scope.id],
        )
        is Some(_) else {
        raise @domain.BadRequest(
          message="reviewer must be an active repository contributor",
        )
      }
      let count : Int64 = tx
        .query_one(
          "SELECT COUNT(*) AS count FROM merge_review_request WHERE merge_request_id = ? AND user_id <> ?",
          params=[mr.id, reviewer],
        )
        .get_name("count")
      guard count < 16L else {
        raise @domain.BadRequest(
          message="a merge request may have at most 16 requested reviewers",
        )
      }
      // Repeated submission of an outstanding request is idempotent. A completed
      // request can be deliberately sent again without clearing its review gate.
      ignore(
        tx.execute(
          "INSERT INTO merge_review_request(merge_request_id, user_id, requested_by, version) VALUES (?, ?, ?, ?) ON CONFLICT(merge_request_id, user_id) DO UPDATE SET requested_by = excluded.requested_by, version = excluded.version, generation = merge_review_request.generation + 1, pending = 1 WHERE merge_review_request.pending = 0 OR merge_review_request.version <> excluded.version",
          params=[mr.id, reviewer, actor.id, version],
        ),
      )
    })
  })
}
