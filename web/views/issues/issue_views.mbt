///|
fn render_issue_list(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  issues : Array[@collaboration.Issue],
  status : String,
  page : Int64,
  mine : Bool,
  query : String,
  contributor : Bool,
  clone : String?,
  manager~ : Bool = false,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(scope.repo)}/issues"
  let filters = "assigned=\{if mine { "me" } else { "all" }}&q=\{@web_context.url_escape_path(query)}"
  @web_ui.layout(
    "Issues",
    assets,
    Html(b => {
      b <+
        "\{@web_ui.render_repo_nav(scope.repo, "HEAD", clone)}<div class=\"mr-page-heading\"><h2>Issues</h2>"
      if contributor {
        b <+ "<a class=\"button-link\" href=\"\{base}/new\">New issue</a>"
      }
      b <+ "</div><nav class=\"mr-tabs\" aria-label=\"Issue status\">"
      for value in ["open", "closed"] {
        b <+ "<a href=\"\{base}?status=\{value}&amp;\{filters}\""
        if status == value {
          b <+ " aria-current=\"page\""
        }
        b <+ ">\{value}</a>"
      }
      b <+
        "</nav><form class=\"issue-filters\" method=\"get\"><input type=\"hidden\" name=\"status\" value=\"\{status}\"><label class=\"field\"><span>Search titles</span><input type=\"search\" name=\"q\" maxlength=\"200\" value=\"\{query}\"></label><label class=\"field\"><span>Assignee</span><select aria-label=\"Assignee\" name=\"assigned\"><option value=\"all\">Anyone</option><option value=\"me\""
      if mine {
        b <+ " selected"
      }
      b <+
        ">Assigned to me</option></select></label><button type=\"submit\">Filter</button></form><ul class=\"mr-list\">"
      for i, issue in issues {
        if i < 50 {
          b <+
            "<li><div class=\"mr-list-title\"><a href=\"\{base}/\{issue.number.to_string()}\">\{issue.title}</a><span class=\"mr-state\" data-state=\"\{issue.status}\">\{issue.status}</span></div><p class=\"muted\">#\{issue.number.to_string()} by \{issue.author} · \{if issue.assignee.is_empty() { "Unassigned" } else { issue.assignee }} · \{issue.updated_at}</p></li>"
        }
      }
      if issues.is_empty() {
        b <+ "<li class=\"muted\">No matching issues.</li>"
      }
      b <+ "</ul><nav class=\"mr-actions\" aria-label=\"Issue pagination\">"
      if page > 1L {
        b <+
          "<a href=\"\{base}?status=\{status}&amp;page=\{(page - 1L).to_string()}&amp;\{filters}\">Previous</a>"
      }
      if issues.length() > 50 {
        b <+
          "<a href=\"\{base}?status=\{status}&amp;page=\{(page + 1L).to_string()}&amp;\{filters}\">Next</a>"
      }
      b <+ "</nav>"
    }),
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(scope.repo, "issues", manager),
  )
}

///|
fn render_issue_form(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  issue : @collaboration.Issue?,
  assignees : Array[@collaboration.IssueAssignee],
  csrf : String,
  form : Map[String, String],
  error : String?,
  manager~ : Bool = false,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(scope.repo)}/issues"
  let title = form
    .get("title")
    .unwrap_or(issue.map(value => value.title).unwrap_or(""))
  let description = form
    .get("description")
    .unwrap_or(issue.map(value => value.description).unwrap_or(""))
  let assignee = form
    .get("assignee")
    .unwrap_or(issue.map(value => value.assignee_id.to_string()).unwrap_or("0"))
  let heading = if issue is Some(_) { "Edit issue" } else { "New issue" }
  let action = issue
    .map(value => "\{base}/\{value.number}/edit")
    .unwrap_or(base)
  @web_ui.layout(
    heading,
    assets,
    Html(b => {
      b <+
        "<a href=\"\{base}\">\{scope.repo.path()} / Issues</a><h1>\{heading}</h1>"
      if error is Some(error) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{error}</p>"
      }
      b <+
        "<form class=\"form-stack mr-form\" method=\"post\" action=\"\{action}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\">"
      if issue is Some(issue) {
        // Keep the submitted version on validation errors: never silently replace a stale edit.
        b <+
          "<input type=\"hidden\" name=\"edit_version\" value=\"\{form.get("edit_version").unwrap_or(issue.edit_version.to_string())}\">"
      }
      b <+
        "<label class=\"field\"><span>Title</span><input name=\"title\" required maxlength=\"200\" value=\"\{title}\"></label><label class=\"field\"><span>Description</span><textarea aria-label=\"Description\" name=\"description\" rows=\"8\" maxlength=\"20000\">\{description}</textarea></label><label class=\"field\"><span>Assignee</span><select aria-label=\"Assignee\" name=\"assignee\"><option value=\"0\">Unassigned</option>"
      for person in assignees {
        let id = person.id
        let name = person.display_name
        let username = person.name_key
        b <+ "<option value=\"\{id.to_string()}\""
        if assignee == id.to_string() {
          b <+ " selected"
        }
        b <+ ">\{name} (@\{username})</option>"
      }
      b <+
        "</select></label><div class=\"mr-actions\"><button type=\"submit\">\{if issue is Some(_) { "Save changes" } else { "Create issue" }}</button><a href=\"\{base}\">Cancel</a></div></form>"
    }),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(scope.repo, "issues", manager),
  )
}

///|
fn render_issue_detail(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  issue : @collaboration.Issue,
  activities : Array[@collaboration.IssueActivity],
  page : Int64,
  related : Array[@collaboration.MergeRequest],
  contributor : Bool,
  manager : Bool,
  csrf : String,
  clone : String?,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(scope.repo)}/issues/\{issue.number}"
  @web_ui.layout(
    "#\{issue.number} \{issue.title}",
    assets,
    Html(b => {
      b <+
        "\{@web_ui.render_repo_nav(scope.repo, "HEAD", clone)}<div class=\"mr-page-heading\"><h2 class=\"mr-title\">\{issue.title} <span class=\"muted\">#\{issue.number.to_string()}</span></h2><span class=\"mr-state\" data-state=\"\{issue.status}\">\{issue.status}</span></div><p class=\"muted\">Opened by \{issue.author} · \{if issue.assignee.is_empty() { "Unassigned" } else { "Assigned to " + issue.assignee }}</p><div class=\"mr-actions\">"
      if contributor {
        if manager || user.id == issue.author_id {
          b <+
            "<a href=\"\{base}/edit\">Edit issue</a><form method=\"post\" action=\"\{base}/\{if issue.status == "open" { "close" } else { "reopen" }}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"edit_version\" value=\"\{issue.edit_version.to_string()}\"><button type=\"submit\">\{if issue.status == "open" { "Close issue" } else { "Reopen issue" }}</button></form>"
        }
        b <+
          "<a href=\"\{@web_ui.repo_link(scope.repo)}/merge-requests/new?issue=\{issue.number.to_string()}\">Create merge request</a>"
      }
      b <+ "</div><div class=\"mr-description\">\{issue.description}</div>"
      if !related.is_empty() {
        b <+
          "<section class=\"issue-related\"><h3>Related merge requests</h3><ul class=\"mr-list\">"
        for mr in related {
          b <+
            "<li><a href=\"\{@web_ui.repo_link(scope.repo)}/merge-requests/\{mr.number.to_string()}\">!\{mr.number.to_string()} \{mr.title}</a> <span class=\"muted\">\{@web_ui.merge_status(mr)}</span></li>"
        }
        b <+ "</ul></section>"
      }
      b <+ "<ol class=\"mr-timeline\">"
      for i, item in activities {
        if i < 50 {
          let actor = item.actor
          let kind = item.kind
          let body = item.body
          let created_at = item.created_at
          b <+
            "<li><div class=\"mr-event-heading\"><strong>\{actor}</strong><span>\{kind}</span><time>\{created_at}</time></div>"
          if !body.is_empty() {
            b <+ "<p class=\"mr-comment\">\{body}</p>"
          }
          b <+ "</li>"
        }
      }
      b <+
        "</ol><nav class=\"mr-actions\" aria-label=\"Issue discussion pagination\">"
      if page > 1L {
        b <+
          "<a href=\"\{base}?page=\{(page - 1L).to_string()}\">Newer activity</a>"
      }
      if activities.length() > 50 {
        b <+
          "<a href=\"\{base}?page=\{(page + 1L).to_string()}\">Older activity</a>"
      }
      b <+ "</nav>"
      if contributor {
        b <+
          "<form class=\"form-stack mr-form\" method=\"post\" action=\"\{base}/comment\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label class=\"field\"><span>Comment</span><textarea aria-label=\"Comment\" name=\"body\" required rows=\"4\" maxlength=\"20000\"></textarea></label><button type=\"submit\">Add comment</button></form>"
      }
    }),
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(scope.repo, "issues", manager),
  )
}
