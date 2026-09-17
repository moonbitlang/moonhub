///|
pub struct Issue {
  id : Int64
  number : Int64
  author_id : Int64
  author : String
  assignee_id : Int64
  assignee : String
  title : String
  description : String
  status : String
  edit_version : Int64
  updated_at : String
}

///|
let issue_select : String =
  #|SELECT i.*, author.display_name AS author,
  #|  COALESCE(assignee.display_name, '') AS assignee, COALESCE(i.assignee_id, 0) AS assigned_id
  #|FROM issue AS i JOIN "user" AS author ON author.id = i.author_id
  #|LEFT JOIN "user" AS assignee ON assignee.id = i.assignee_id

///|
fn Issue::from_row(row : @database.DbRow) -> Issue raise {
  {
    id: row.get_name("id"),
    number: row.get_name("number"),
    author_id: row.get_name("author_id"),
    author: row.get_name("author"),
    assignee_id: row.get_name("assigned_id"),
    assignee: row.get_name("assignee"),
    title: row.get_name("title"),
    description: row.get_name("description"),
    status: row.get_name("status"),
    edit_version: row.get_name("edit_version"),
    updated_at: row.get_name("updated_at"),
  }
}

///|
pub fn require_issue(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  number : Int64,
) -> Issue raise {
  pool.with_client(client => {
    let row = client.query_opt(
      "\{issue_select} WHERE i.repository_id = ? AND i.number = ?",
      params=[scope.id, number],
    )
    guard row is Some(row) else {
      raise @domain.NotFound(message="issue not found")
    }
    Issue::from_row(row)
  })
}

///|
pub fn issue_assignees(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
) -> Array[IssueAssignee] raise {
  pool.with_client(client => {
    client
    .query_all(
      "SELECT u.id, u.display_name, u.name_key FROM \"user\" AS u JOIN team_member AS tm ON tm.user_id = u.id WHERE tm.team_id = ? AND u.status = 'active' ORDER BY u.name_key",
      params=[scope.team_id],
    )
    .map(row => {
      id: row.get_name("id"),
      display_name: row.get_name("display_name"),
      name_key: row.get_name("name_key"),
    })
  })
}

///|
pub struct IssueAssignee {
  id : Int64
  display_name : String
  name_key : String
}

///|
pub struct IssueActivity {
  actor : String
  kind : String
  body : String
  created_at : String
}

///|
pub fn list_issues(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  status : String,
  page : Int64,
  mine : Bool,
  actor_id : Int64,
  query : String,
) -> Array[Issue] raise {
  pool.with_client(client => {
    client
    .query_all(
      "\{issue_select} WHERE i.repository_id = ? AND i.status = ? AND (? = 0 OR i.assignee_id = ?) AND (? = '' OR instr(lower(i.title), lower(?)) > 0) ORDER BY i.number DESC LIMIT 51 OFFSET ?",
      params=[scope.id, status, mine, actor_id, query, query, (page - 1L) * 50L],
    )
    .map(Issue::from_row)
  })
}

///|
pub fn list_issue_activity(
  pool : @database.Database,
  issue : Issue,
  page : Int64,
) -> Array[IssueActivity] raise {
  pool.with_client(client => {
    client
    .query_all(
      "SELECT a.*, u.display_name AS actor FROM issue_activity AS a JOIN \"user\" AS u ON u.id = a.actor_id WHERE a.issue_id = ? ORDER BY a.id DESC LIMIT 51 OFFSET ?",
      params=[issue.id, (page - 1L) * 50L],
    )
    .map(row => {
      actor: row.get_name("actor"),
      kind: row.get_name("kind"),
      body: row.get_name("body"),
      created_at: row.get_name("created_at"),
    })
  })
}
