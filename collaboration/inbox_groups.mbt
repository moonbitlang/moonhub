///|
pub struct InboxGroup {
  item : InboxItem
  status : String
  unread : Int64
  events : Array[InboxItem]
}

///|
pub fn InboxGroup::url(self : InboxGroup) -> String {
  { ..self.item, id: 0L, discussion_id: None, comment_id: None, }.url()
}

///|
pub fn inbox_groups(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  filter : String,
  page : Int64,
) -> Array[InboxGroup] raise {
  guard ["unread", "all", "reviews", "assigned"].contains(filter) &&
    page > 0L &&
    page <= 100000L else {
    raise @domain.BadRequest(message="invalid inbox filter or page")
  }
  let items = if filter == "reviews" || filter == "assigned" {
    inbox_items(pool, actor, filter, page)
  } else {
    pool.with_client(client => {
      client
      .query_all(
        "WITH ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY id DESC) AS position FROM collaboration_notification_visible WHERE user_id = ? AND (? = 'all' OR read_at IS NULL)) SELECT *, issue_id IS NOT NULL AS is_issue, read_at IS NOT NULL AS is_read FROM ranked WHERE position = 1 ORDER BY id DESC LIMIT 51 OFFSET ?",
        params=[actor.id, filter, (page - 1L) * 50L],
      )
      .map(InboxItem::from_row)
    })
  }
  if items.is_empty() {
    return []
  }
  let ids = items.map(item => item.thread_id.to_string()).join(",")
  pool.with_client(client => {
    let metadata : Map[Int64, (String, Int64)] = Map([])
    for
      row in client.query_all(
        "SELECT t.id, COALESCE(i.status, m.status) AS status, (SELECT COUNT(*) FROM collaboration_notification_visible v WHERE v.thread_id = t.id AND v.user_id = ? AND v.read_at IS NULL) AS unread FROM collaboration_thread t LEFT JOIN issue i ON i.id = t.issue_id LEFT JOIN merge_request m ON m.id = t.merge_request_id WHERE t.id IN (\{ids})",
        params=[actor.id],
      ) {
      metadata.set(
        row.get_name("id"),
        (row.get_name("status"), row.get_name("unread")),
      )
    }
    let history : Map[Int64, Array[InboxItem]] = Map([])
    for
      row in client.query_all(
        "WITH ranked AS (SELECT *, ROW_NUMBER() OVER (PARTITION BY thread_id ORDER BY id DESC) AS position FROM collaboration_notification_visible WHERE user_id = ? AND thread_id IN (\{ids})) SELECT *, issue_id IS NOT NULL AS is_issue, read_at IS NOT NULL AS is_read FROM ranked WHERE position <= 10 ORDER BY id DESC",
        params=[actor.id],
      ) {
      let item = InboxItem::from_row(row)
      let events = history.get_or_init(item.thread_id, () => [])
      events.push(item)
    }
    items.map(item => {
      let (status, unread) = metadata.get(item.thread_id).unwrap_or(("", 0L))
      {
        item,
        status,
        unread,
        events: history.get(item.thread_id).unwrap_or([]),
      }
    })
  })
}

///|
pub fn mark_thread_notifications_read(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  thread : Int64,
  through : Int64,
) -> Unit raise {
  pool.with_client(client => {
    guard client.query_opt(
        "SELECT id FROM collaboration_notification_visible WHERE thread_id = ? AND user_id = ? LIMIT 1",
        params=[thread, actor.id],
      )
      is Some(_) else {
      raise @domain.NotFound(message="notification thread not found")
    }
    ignore(
      client.execute(
        "UPDATE collaboration_notification SET read_at = COALESCE(read_at, datetime('now')) WHERE user_id = ? AND id <= ? AND id IN (SELECT id FROM collaboration_notification_visible WHERE thread_id = ? AND user_id = ?)",
        params=[actor.id, through, thread, actor.id],
      ),
    )
  })
}
