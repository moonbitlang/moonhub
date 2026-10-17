///|
pub struct InboxItem {
  id : Int64
  thread_id : Int64
  repo : @domain.RepoId
  number : Int64
  title : String
  issue : Bool
  kind : String
  actor : String
  version : Int64
  discussion_id : Int64?
  comment_id : Int64?
  read : Bool
  created_at : String
}

///|
pub fn InboxItem::url(self : InboxItem) -> String {
  let path = "/\{self.repo.path()}/\{if self.issue { "issues" } else { "merge-requests" }}/\{self.number}"
  if !self.issue && self.id > 0L && self.discussion_id is Some(discussion) {
    let comment = self.comment_id
      .map(id => "&comment=\{id.to_string()}")
      .unwrap_or("")
    return "\{path}?discussion=\{discussion.to_string()}\{comment}" +
      self.comment_id
      .map(id => "#comment-\{id.to_string()}")
      .unwrap_or("#discussion-\{discussion.to_string()}")
  }
  if !self.issue && self.version > 0L && self.id > 0L {
    "\{path}?version=\{self.version}"
  } else {
    path
  }
}

///|
pub fn notification_label(kind : String) -> String {
  match kind {
    "review_requested" => "Review requested"
    "assigned" => "Assigned to you"
    "comment" => "New comment"
    "discussion_resolved" => "Discussion resolved"
    "discussion_reopened" => "Discussion reopened"
    "approved" => "Review approved"
    "changes_requested" => "Changes requested"
    "withdrawn" => "Review withdrawn"
    "merged" => "Merge request merged"
    "close" => "Closed"
    "reopen" => "Reopened"
    "ready" => "Ready for review"
    "updated" => "New version to review"
    "checks_failed" => "Pipeline checks failed"
    "checks_awaiting_approval" => "Checks need execution approval"
    _ => "New activity"
  }
}

///|
fn InboxItem::from_row(row : @database.DbRow) -> InboxItem raise {
  {
    id: row.get_name("id"),
    thread_id: row.get_name("thread_id"),
    repo: {
      owner: row.get_name("owner"),
      name: row.get_name("repository_name"),
    },
    number: row.get_name("number"),
    title: row.get_name("title"),
    issue: row.get_name("is_issue"),
    kind: row.get_name("kind"),
    actor: row.get_name("actor"),
    version: row.get_name("version"),
    discussion_id: row.get_name("discussion_id"),
    comment_id: row.get_name("comment_id"),
    read: row.get_name("is_read"),
    created_at: row.get_name("created_at"),
  }
}

///|
pub fn inbox_items(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  filter : String,
  page : Int64,
) -> Array[InboxItem] raise {
  guard ["unread", "all", "reviews", "assigned"].contains(filter) &&
    page > 0L &&
    page <= 100000L else {
    raise @domain.BadRequest(message="invalid inbox filter or page")
  }
  pool.with_client(client => {
    let sql = match filter {
      "reviews" =>
        (
          #|SELECT 0 AS id, t.id AS thread_id, owner.name_key AS owner, r.name AS repository_name,
          #|m.number, m.title, 0 AS is_issue, 'review_requested' AS kind, '' AS actor,
          #|m.current_version AS version, NULL AS discussion_id, NULL AS comment_id, 1 AS is_read, m.updated_at AS created_at
          #|FROM merge_review_request q JOIN merge_request m ON m.id = q.merge_request_id
          #|JOIN collaboration_thread t ON t.merge_request_id = m.id
          #|JOIN collaboration_access a ON a.repository_id = t.repository_id AND a.user_id = q.user_id AND a.contributor = 1
          #|JOIN repository r ON r.id = t.repository_id JOIN team owner ON owner.id = r.team_id
          #|WHERE q.user_id = ? AND q.pending = 1 AND m.status = 'open' AND m.draft = 0
          #|ORDER BY m.updated_at DESC, m.id DESC LIMIT 51 OFFSET ?
        )
      "assigned" =>
        (
          #|SELECT 0 AS id, t.id AS thread_id, owner.name_key AS owner, r.name AS repository_name,
          #|i.number, i.title, 1 AS is_issue, 'assigned' AS kind, '' AS actor,
          #|0 AS version, NULL AS discussion_id, NULL AS comment_id, 1 AS is_read, i.updated_at AS created_at
          #|FROM issue i JOIN collaboration_thread t ON t.issue_id = i.id
          #|JOIN collaboration_access a ON a.repository_id = t.repository_id AND a.user_id = i.assignee_id
          #|JOIN repository r ON r.id = t.repository_id JOIN team owner ON owner.id = r.team_id
          #|WHERE i.assignee_id = ? AND i.status = 'open'
          #|ORDER BY i.updated_at DESC, i.id DESC LIMIT 51 OFFSET ?
        )
      _ =>
        "SELECT *, issue_id IS NOT NULL AS is_issue, read_at IS NOT NULL AS is_read FROM collaboration_notification_visible WHERE user_id = ?\{if filter == "unread" { " AND read_at IS NULL" } else { "" }} ORDER BY id DESC LIMIT 51 OFFSET ?"
    }
    client
    .query_all(sql, params=[actor.id, (page - 1L) * 50L])
    .map(InboxItem::from_row)
  })
}

///|
pub fn unread_notification_count(
  pool : @database.Database,
  actor : @domain.CurrentUser,
) -> Int64 raise {
  pool.with_client(client => {
    client
    .query_one(
      "SELECT COUNT(*) AS count FROM collaboration_notification_visible WHERE user_id = ? AND read_at IS NULL",
      params=[actor.id],
    )
    .get_name("count")
  })
}

///|
pub fn mark_notification_read(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  id : Int64,
) -> InboxItem raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let row = tx.query_opt(
        "SELECT *, issue_id IS NOT NULL AS is_issue, read_at IS NOT NULL AS is_read FROM collaboration_notification_visible WHERE id = ? AND user_id = ?",
        params=[id, actor.id],
      )
      guard row is Some(row) else {
        raise @domain.NotFound(message="notification not found")
      }
      ignore(
        tx.execute(
          "UPDATE collaboration_notification SET read_at = COALESCE(read_at, datetime('now')) WHERE id = ?",
          params=[id],
        ),
      )
      InboxItem::from_row(row)
    })
  })
}

///|
pub fn mark_all_notifications_read(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  through : Int64,
) -> Unit raise {
  pool.with_client(client => {
    ignore(
      client.execute(
        "UPDATE collaboration_notification SET read_at = datetime('now') WHERE user_id = ? AND read_at IS NULL AND id <= ? AND id IN (SELECT id FROM collaboration_notification_visible WHERE user_id = ?)",
        params=[actor.id, through, actor.id],
      ),
    )
  })
}

///|
pub struct ThreadSubscription {
  id : Int64
  subscribed : Bool
}

///|
pub fn thread_subscription(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  object_id : Int64,
  issue : Bool,
) -> ThreadSubscription raise {
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Read)
  pool.with_client(client => {
    let row = client.query_opt(
      "SELECT t.id, COALESCE(s.subscribed, 0) AS subscribed FROM collaboration_thread t LEFT JOIN notification_subscription s ON s.thread_id = t.id AND s.user_id = ? WHERE t.repository_id = ? AND \{if issue { "t.issue_id" } else { "t.merge_request_id" }} = ?",
      params=[actor.id, scope.id, object_id],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="discussion not found")
    }
    { id: row.get_name("id"), subscribed: row.get_name("subscribed"), }
  })
}

///|
pub fn set_thread_subscription(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  id : Int64,
  subscribed : Bool,
) -> String raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let row = tx.query_opt(
        (
          #|SELECT owner.name_key AS owner, r.name AS repository_name,
          #|t.issue_id IS NOT NULL AS is_issue, COALESCE(i.number, m.number) AS number
          #|FROM collaboration_thread t JOIN collaboration_access a ON a.repository_id = t.repository_id AND a.user_id = ?
          #|JOIN repository r ON r.id = t.repository_id JOIN team owner ON owner.id = r.team_id
          #|LEFT JOIN issue i ON i.id = t.issue_id LEFT JOIN merge_request m ON m.id = t.merge_request_id WHERE t.id = ?
        ),
        params=[actor.id, id],
      )
      guard row is Some(row) else {
        raise @domain.NotFound(message="discussion not found")
      }
      ignore(
        tx.execute(
          "INSERT INTO notification_subscription(thread_id, user_id, subscribed) VALUES (?, ?, ?) ON CONFLICT(thread_id, user_id) DO UPDATE SET subscribed = excluded.subscribed",
          params=[id, actor.id, subscribed],
        ),
      )
      let owner : String = row.get_name("owner")
      let name : String = row.get_name("repository_name")
      let number : Int64 = row.get_name("number")
      let issue : Bool = row.get_name("is_issue")
      "/\{owner}/\{name}/\{if issue { "issues" } else { "merge-requests" }}/\{number}"
    })
  })
}

///|
pub fn notification_email_enabled(
  pool : @database.Database,
  actor : @domain.CurrentUser,
) -> Bool raise {
  pool.with_client(client => {
    client
    .query_one(
      "SELECT COALESCE((SELECT email_enabled FROM notification_preferences WHERE user_id = ?), 0) AS enabled",
      params=[actor.id],
    )
    .get_name("enabled")
  })
}

///|
pub fn set_notification_email(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  enabled : Bool,
) -> Unit raise {
  pool.with_client(client => {
    guard client.query_opt(
        "SELECT id FROM \"user\" WHERE id = ? AND status = 'active'",
        params=[actor.id],
      )
      is Some(_) else {
      raise @domain.Forbidden(message="active account required")
    }
    ignore(
      client.execute(
        "INSERT INTO notification_preferences(user_id, email_enabled) VALUES (?, ?) ON CONFLICT(user_id) DO UPDATE SET email_enabled = excluded.email_enabled",
        params=[actor.id, enabled],
      ),
    )
  })
}
