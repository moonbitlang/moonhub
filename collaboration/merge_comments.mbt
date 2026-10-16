///|
// Only plain comments can be hidden. Review decisions and lifecycle events
// remain audit history; hiding a comment must never change merge readiness.
pub fn set_merge_comment_deleted(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  comment_id : Int64,
  version : Int64,
  deleted : Bool,
) -> Unit raise {
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  guard mr.repository_id == scope.id else {
    raise @domain.NotFound(message="merge request not found")
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      let row = tx.query_opt(
        "SELECT actor_id, kind, version, body FROM merge_activity WHERE id = ? AND merge_request_id = ?",
        params=[comment_id, mr.id],
      )
      guard row is Some(row) else {
        raise @domain.NotFound(message="comment not found")
      }
      let kind : String = row.get_name("kind")
      guard kind == "comment" || kind == "comment_deleted" else {
        raise @domain.BadRequest(
          message="only plain comments can be deleted or restored",
        )
      }
      guard (row.get_name("actor_id") : Int64?) == Some(actor.id) ||
        @identity.can_manage_team(pool, actor, scope.team_id) else {
        raise @domain.Forbidden(
          message="only the comment author or a team administrator may delete or restore this comment",
        )
      }
      guard (row.get_name("version") : Int64) == version else {
        raise @domain.BadRequest(
          message="comment version changed; reload before saving",
        )
      }
      let next = if deleted { "comment_deleted" } else { "comment" }
      if kind == next {
        return
      }
      // Keep the recovery copy in the private repository audit. Clear the
      // public activity body so older readers cannot disclose deleted text.
      let body : String = if deleted {
        row.get_name("body")
      } else {
        tx
        .query_one(
          "SELECT json_extract(detail, '$.body') AS body FROM repository_audit WHERE repository_id = ? AND kind = 'mr_comment_deleted' AND json_extract(detail, '$.comment') = ? AND json_extract(detail, '$.mr') = ? ORDER BY id DESC LIMIT 1",
          params=[scope.id, comment_id.to_string(), mr.id.to_string()],
        )
        .get_name("body")
      }
      ignore(
        tx.execute(
          "UPDATE merge_activity SET kind = ?, body = ? WHERE id = ? AND merge_request_id = ?",
          params=[next, if deleted { "" } else { body }, comment_id, mr.id],
        ),
      )
      ignore(
        tx.execute(
          "INSERT INTO repository_audit(repository_id, actor_id, kind, detail) VALUES (?, ?, ?, ?)",
          params=[
            scope.id,
            actor.id,
            if deleted {
              "mr_comment_deleted"
            } else {
              "mr_comment_restored"
            },
            (
              {
                "mr": mr.id.to_string(),
                "comment": comment_id.to_string(),
                "version": version.to_string(),
                "body": if deleted {
                  body
                } else {
                  ""
                },
              } : Json).stringify(),
          ],
        ),
      )
    })
  })
}
