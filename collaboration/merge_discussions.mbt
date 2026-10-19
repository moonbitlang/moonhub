///|
pub struct MergeDiscussion {
  id : Int64
  version : Int64
  resolved : Bool
  state_version : Int64
  state_actor : String
  state_changed_at : String
  can_resolve : Bool
  root : MergeActivity
  replies : Array[MergeActivity]
  reply_count : Int64
  anchor : @gitops.DiffAnchor?
}

///|
fn require_discussion_access(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  write : Bool,
) -> Unit raise {
  @repository.authorize_repository(
    pool,
    actor,
    scope.repo,
    if write {
      Write
    } else {
      Read
    },
  )
  guard mr.repository_id == scope.id else {
    raise @domain.NotFound(message="merge request not found")
  }
}

///|
fn MergeActivity::from_discussion_row(
  row : @database.DbRow,
) -> MergeActivity raise {
  {
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
  }
}

///|
let discussion_select : String =
  #|SELECT d.*, COALESCE(u.display_name, '') AS state_actor,
  #|COALESCE(d.state_changed_at, '') AS changed_at,
  #|(SELECT COUNT(*) FROM merge_activity a WHERE a.discussion_id = d.id AND a.id <> d.id AND a.kind IN ('comment', 'comment_deleted')) AS reply_count
  #|FROM merge_discussion d LEFT JOIN "user" u ON u.id = d.state_actor_id

///|
fn load_merge_discussions(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  filter : String,
  page : Int64,
  selected : Int64?,
  anchor_version : Int64,
  comparison : @gitops.RevisionComparison?,
) -> Array[MergeDiscussion] raise {
  require_discussion_access(pool, scope, actor, mr, false)
  guard page > 0L && page <= 100000L else {
    raise @domain.BadRequest(message="invalid discussion page")
  }
  guard ["all", "unresolved", "resolved"].contains(filter) else {
    raise @domain.BadRequest(message="invalid discussion filter")
  }
  let manager = @identity.can_manage_team(pool, actor, scope.team_id)
  let contributor = @repository.can_access_repository(
    pool,
    actor,
    scope.repo,
    Write,
  )
  pool.with_client(client => {
    let rows = match selected {
      Some(id) =>
        client.query_all(
          "\{discussion_select} WHERE d.merge_request_id = ? AND d.id = ?",
          params=[mr.id, id],
        )
      None =>
        client.query_all(
          "\{discussion_select} WHERE d.merge_request_id = ? AND (? = 'all' OR d.resolved = ?) AND (? = 0 OR (d.version = ? AND json_extract(d.anchor, '$.base_sha') = ? AND json_extract(d.anchor, '$.head_sha') = ? AND json_extract(d.anchor, '$.commit_sha') = ?)) ORDER BY d.id DESC LIMIT 51 OFFSET ?",
          params=[
            mr.id,
            filter,
            filter == "resolved",
            anchor_version,
            anchor_version,
            comparison.map(c => c.base_sha).unwrap_or(""),
            comparison.map(c => c.head_sha).unwrap_or(""),
            comparison
            .map(c => c.commit.map(commit => commit.hash).unwrap_or(""))
            .unwrap_or(""),
            (page - 1L) * 50L,
          ],
        )
    }
    if rows.is_empty() {
      if selected is Some(_) {
        raise @domain.NotFound(message="discussion not found")
      }
      return []
    }
    let ids = rows
      .map(row => (row.get_name("id") : Int64).to_string())
      .join(",")
    let roots = client.query_all(
      "SELECT a.*, COALESCE(u.display_name, 'Moonhub') AS actor FROM merge_activity a LEFT JOIN \"user\" u ON u.id = a.actor_id WHERE a.id IN (\{ids})",
    )
    let root_map : Map[Int64, MergeActivity] = Map([])
    for row in roots {
      let root = MergeActivity::from_discussion_row(row)
      root_map[root.id] = root
    }
    // Overview batches three recent replies per thread; detail pages fifty replies.
    let replies = match selected {
      Some(id) =>
        client.query_all(
          "SELECT a.*, COALESCE(u.display_name, 'Moonhub') AS actor FROM merge_activity a LEFT JOIN \"user\" u ON u.id = a.actor_id WHERE a.discussion_id = ? AND a.id <> ? AND a.kind IN ('comment', 'comment_deleted') ORDER BY a.id LIMIT 50 OFFSET ?",
          params=[id, id, (page - 1L) * 50L],
        )
      None =>
        client.query_all(
          "WITH ranked AS (SELECT a.*, ROW_NUMBER() OVER (PARTITION BY a.discussion_id ORDER BY a.id DESC) AS position FROM merge_activity a WHERE a.discussion_id IN (\{ids}) AND a.id <> a.discussion_id AND a.kind IN ('comment', 'comment_deleted')) SELECT a.*, COALESCE(u.display_name, 'Moonhub') AS actor FROM ranked a LEFT JOIN \"user\" u ON u.id = a.actor_id WHERE a.position <= 3 ORDER BY a.id",
        )
    }
    let reply_map : Map[Int64, Array[MergeActivity]] = Map([])
    for row in replies {
      let reply = MergeActivity::from_discussion_row(row)
      reply_map.get_or_init(reply.discussion_id.unwrap(), () => []).push(reply)
    }
    rows.map(row => {
      let id : Int64 = row.get_name("id")
      {
        id,
        version: row.get_name("version"),
        resolved: row.get_name("resolved"),
        state_version: row.get_name("state_version"),
        state_actor: row.get_name("state_actor"),
        state_changed_at: row.get_name("changed_at"),
        can_resolve: contributor &&
        (
          manager ||
          actor.id == mr.author_id ||
          Some(actor.id) == (row.get_name("author_id") : Int64?)
        ),
        root: root_map.get(id).unwrap(),
        replies: reply_map.get(id).unwrap_or([]),
        reply_count: row.get_name("reply_count"),
        anchor: (row.get_name("anchor") : String?).map(value => {
          @json.from_json(@json.parse(value))
        }),
      }
    })
  })
}

///|
pub fn list_merge_discussions(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  page : Int64,
  filter~ : String = "all",
  anchor_version~ : Int64 = 0L,
  comparison~ : @gitops.RevisionComparison? = None,
) -> Array[MergeDiscussion] raise {
  load_merge_discussions(
    pool,
    scope,
    actor,
    mr,
    filter,
    page,
    None,
    anchor_version,
    comparison,
  )
}

///|
pub fn merge_discussion(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  id : Int64,
  page~ : Int64 = 1L,
) -> MergeDiscussion raise {
  load_merge_discussions(
    pool,
    scope,
    actor,
    mr,
    "all",
    page,
    Some(id),
    0L,
    None,
  )[0]
}

///|
pub fn unresolved_merge_discussions(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
) -> Int64 raise {
  require_discussion_access(pool, scope, actor, mr, false)
  pool.with_client(client => {
    client
    .query_one(
      "SELECT COUNT(*) AS count FROM merge_discussion WHERE merge_request_id = ? AND resolved = 0",
      params=[mr.id],
    )
    .get_name("count")
  })
}

///|
pub fn reply_merge_discussion(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  id : Int64,
  body : String,
) -> Int64 raise {
  require_discussion_access(pool, scope, actor, mr, true)
  guard !body.trim().is_empty() && body.length() <= 20000 else {
    raise @domain.BadRequest(
      message="reply must contain between 1 and 20,000 characters",
    )
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      let row = tx.query_opt(
        "SELECT version FROM merge_discussion WHERE id = ? AND merge_request_id = ?",
        params=[id, mr.id],
      )
      guard row is Some(row) else {
        raise @domain.NotFound(message="discussion not found")
      }
      let version : Int64 = row.get_name("version")
      ignore(
        tx.execute(
          "INSERT INTO merge_activity(merge_request_id, actor_id, kind, body, version, discussion_id) VALUES (?, ?, 'comment', ?, ?, ?)",
          params=[mr.id, actor.id, body, version, id],
        ),
      )
      tx.query_one("SELECT last_insert_rowid() AS id").get_name("id")
    })
  })
}

///|
pub fn set_merge_discussion_resolved(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  id : Int64,
  state_version : Int64,
  resolved : Bool,
) -> Unit raise {
  require_discussion_access(pool, scope, actor, mr, true)
  let manager = @identity.can_manage_team(pool, actor, scope.team_id)
  pool.with_client(client => {
    client.with_transaction(tx => {
      let row = tx.query_opt(
        "SELECT author_id, resolved, state_version FROM merge_discussion WHERE id = ? AND merge_request_id = ?",
        params=[id, mr.id],
      )
      guard row is Some(row) else {
        raise @domain.NotFound(message="discussion not found")
      }
      guard manager ||
        actor.id == mr.author_id ||
        Some(actor.id) == (row.get_name("author_id") : Int64?) else {
        raise @domain.Forbidden(
          message="only the discussion author, MR author or a team administrator may resolve or reopen this discussion",
        )
      }
      guard (row.get_name("state_version") : Int64) == state_version else {
        raise @domain.BadRequest(
          message="discussion state changed; reload before saving",
        )
      }
      if (row.get_name("resolved") : Bool) == resolved {
        return
      }
      ignore(
        tx.execute(
          "UPDATE merge_discussion SET resolved = ?, state_version = state_version + 1, state_actor_id = ?, state_changed_at = datetime('now') WHERE id = ? AND merge_request_id = ? AND state_version = ?",
          params=[resolved, actor.id, id, mr.id, state_version],
        ),
      )
    })
  })
}

///|
// Resolve a stable comment ID to its current page; deleted replies still occupy
// their original position, so old notifications and restore actions stay valid.
pub fn merge_discussion_comment_page(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  discussion : Int64,
  comment : Int64,
) -> Int64 raise {
  require_discussion_access(pool, scope, actor, mr, false)
  pool.with_client(client => {
    let row = client.query_opt(
      "SELECT c.id, (SELECT COUNT(*) FROM merge_activity a WHERE a.discussion_id = c.discussion_id AND a.id <> a.discussion_id AND a.id < c.id AND a.kind IN ('comment', 'comment_deleted')) AS preceding FROM merge_activity c JOIN merge_discussion d ON d.id = c.discussion_id WHERE d.id = ? AND d.merge_request_id = ? AND c.merge_request_id = d.merge_request_id AND c.id = ? AND (c.id = d.id OR c.kind IN ('comment', 'comment_deleted'))",
      params=[discussion, mr.id, comment],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="discussion comment not found")
    }
    (row.get_name("preceding") : Int64) / 50L + 1L
  })
}

///|
pub async fn create_anchored_merge_discussion(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  actor : @domain.CurrentUser,
  mr : MergeRequest,
  git_dir : String,
  version : Int64,
  commit : String?,
  path : String,
  side : String,
  start_line : Int64,
  end_line : Int64,
  body : String,
) -> Int64 {
  require_discussion_access(pool, scope, actor, mr, true)
  let body = body.trim().to_owned()
  guard !body.is_empty() && body.length() <= 20000 else {
    raise @domain.BadRequest(
      message="comment must contain 1–20000 characters",
    )
  }
  let revision = merge_revision(pool, mr, version~)
  let anchor = @gitops.validate_diff_anchor(
    git_dir, revision, commit, path, side, start_line, end_line,
  )
  require_discussion_access(pool, scope, actor, mr, true)
  // Root trigger, anchor and notifications commit atomically.
  pool.with_client(client => {
    client.with_transaction(tx => {
      ignore(
        tx.execute(
          "INSERT INTO merge_activity(merge_request_id, actor_id, kind, body, version) VALUES (?, ?, 'comment', ?, ?)",
          params=[mr.id, actor.id, body, version],
        ),
      )
      let id : Int64 = tx
        .query_one("SELECT last_insert_rowid() AS id")
        .get_name("id")
      ignore(
        tx.execute(
          "UPDATE merge_discussion SET anchor = ? WHERE id = ? AND merge_request_id = ?",
          params=[Json(anchor).stringify(), id, mr.id],
        ),
      )
      id
    })
  })
}
