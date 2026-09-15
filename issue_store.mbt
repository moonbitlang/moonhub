///|
struct Issue {
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
fn Issue::from_row(row : DbRow) -> Issue raise {
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
fn require_issue(
  pool : Database,
  scope : RepositoryScope,
  number : Int64,
) -> Issue raise {
  pool.with_client(client => {
    let row = client.query_opt(
      "\{issue_select} WHERE i.repository_id = ? AND i.number = ?",
      params=[scope.id, number],
    )
    guard row is Some(row) else { raise NotFound(message="issue not found") }
    Issue::from_row(row)
  })
}

///|
fn issue_assignees(
  pool : Database,
  scope : RepositoryScope,
) -> Array[DbRow] raise {
  pool.with_client(client => {
    client.query_all(
      "SELECT u.id, u.display_name, u.name_key FROM \"user\" AS u JOIN team_member AS tm ON tm.user_id = u.id WHERE tm.team_id = ? AND u.status = 'active' ORDER BY u.name_key",
      params=[scope.team_id],
    )
  })
}
