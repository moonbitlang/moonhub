///|
fn validate_issue_content(title : String, description : String) -> Unit raise {
  guard !title.trim().is_empty() &&
    title.length() <= 200 &&
    description.length() <= 20000 else {
    raise @domain.BadRequest(
      message="title must be 1-200 characters and description at most 20000 characters",
    )
  }
}

///|
fn validate_issue_assignee(
  tx : @database.DbTransaction,
  scope : @repository.RepositoryScope,
  id : Int64,
) -> Unit raise {
  guard id == 0L ||
    tx.query_opt(
      "SELECT u.id FROM \"user\" AS u JOIN team_member AS tm ON tm.user_id = u.id WHERE tm.team_id = ? AND u.id = ? AND u.status = 'active'",
      params=[scope.team_id, id],
    )
    is Some(_) else {
    raise @domain.BadRequest(
      message="assignee must be an active member of this team",
    )
  }
}

///|
pub fn create_issue(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  title : String,
  description : String,
  assignee : Int64,
) -> Int64 raise {
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  let title = title.trim().to_owned()
  validate_issue_content(title, description)
  pool.with_client(client => {
    client.with_transaction(tx => {
      validate_issue_assignee(tx, scope, assignee)
      let row = tx.query_one(
        "SELECT COALESCE(MAX(number), 0) + 1 AS number FROM issue WHERE repository_id = ?",
        params=[scope.id],
      )
      let number : Int64 = row.get_name("number")
      let row = tx.query_one(
        "INSERT INTO issue (repository_id, number, author_id, title, description, assignee_id) VALUES (?, ?, ?, ?, ?, NULLIF(?, 0)) RETURNING id",
        params=[scope.id, number, actor.id, title, description, assignee],
      )
      let id : Int64 = row.get_name("id")
      let _ = tx.execute(
        "INSERT INTO issue_activity (issue_id, actor_id, kind) VALUES (?, ?, 'opened')",
        params=[id, actor.id],
      )
      number
    })
  })
}

///|
pub fn mutate_issue(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  issue : Issue,
  expected : Int64,
  action : String,
  title : String,
  description : String,
  assignee : Int64,
  body : String,
) -> Unit raise {
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  if action != "comment" {
    guard actor.id == issue.author_id ||
      @identity.can_manage_team(pool, actor, scope.team_id) else {
      raise @domain.Forbidden(
        message="only the author or a team administrator may change this issue",
      )
    }
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      if action == "comment" {
        guard !body.trim().is_empty() && body.length() <= 20000 else {
          raise @domain.BadRequest(
            message="comment must contain 1-20000 characters",
          )
        }
        let _ = tx.execute(
          "INSERT INTO issue_activity (issue_id, actor_id, kind, body) VALUES (?, ?, 'comment', ?)",
          params=[issue.id, actor.id, body],
        )
        let _ = tx.execute(
          "UPDATE issue SET updated_at = datetime('now') WHERE id = ?",
          params=[issue.id],
        )
      } else {
        guard expected == issue.edit_version else {
          raise @domain.BadRequest(
            message="this issue changed; reload before saving",
          )
        }
        let changed = if action == "edit" {
          let title = title.trim().to_owned()
          validate_issue_content(title, description)
          validate_issue_assignee(tx, scope, assignee)
          tx.execute(
            "UPDATE issue SET title = ?, description = ?, assignee_id = NULLIF(?, 0), edit_version = edit_version + 1, updated_at = datetime('now') WHERE id = ? AND edit_version = ?",
            params=[title, description, assignee, issue.id, expected],
          )
        } else {
          guard action == "close" || action == "reopen" else {
            raise @domain.BadRequest(message="invalid issue action")
          }
          tx.execute(
            "UPDATE issue SET status = ?, closed_at = CASE WHEN ? = 'close' THEN datetime('now') ELSE NULL END, edit_version = edit_version + 1, updated_at = datetime('now') WHERE id = ? AND edit_version = ?",
            params=[
              if action == "close" {
                "closed"
              } else {
                "open"
              },
              action,
              issue.id,
              expected,
            ],
          )
        }
        guard changed == 1 else {
          raise @domain.BadRequest(
            message="this issue changed; reload before saving",
          )
        }
        if action == "edit" && assignee != issue.assignee_id && assignee != 0L {
          ignore(
            tx.execute(
              "INSERT INTO issue_activity (issue_id, actor_id, kind) VALUES (?, ?, 'assigned')",
              params=[issue.id, actor.id],
            ),
          )
        }
        let _ = tx.execute(
          "INSERT INTO issue_activity (issue_id, actor_id, kind, body) VALUES (?, ?, ?, ?)",
          params=[
            issue.id,
            actor.id,
            action,
            if action == "edit" {
              "Updated title, description or assignee."
            } else {
              ""
            },
          ],
        )
      }
    })
  })
}
