///|
fn merge_status(mr : MergeRequest) -> String {
  if mr.status == "merged" {
    "Merged"
  } else if mr.status == "closed" {
    "Closed"
  } else if mr.job_status == "pending" || mr.job_status == "running" {
    "Merging"
  } else if mr.draft {
    "Draft"
  } else {
    "Open"
  }
}

///|
fn merge_action(
  base : String,
  csrf : String,
  action : String,
  label : String,
  version : Int64,
  edit_version? : Int64 = 1L,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<form method=\"post\" action=\"\{base}/\{action}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{version.to_string()}\"><input type=\"hidden\" name=\"edit_version\" value=\"\{edit_version.to_string()}\"><button type=\"submit\">\{label}</button></form>"
  })
}

///|
fn render_merge_list(
  assets : Map[String, String],
  user : CurrentUser,
  scope : RepositoryScope,
  rows : Array[MergeRequest],
  status : String,
  page : Int64,
  contributor : Bool,
  manager : Bool,
  clone : String?,
) -> @moonback.Html {
  let base = "\{repo_link(scope.repo)}/merge-requests"
  layout(
    "Merge Requests",
    assets,
    Html(b => {
      b <+
        "\{render_repo_nav(scope.repo, "HEAD", clone)}<div class=\"mr-page-heading\"><h2>Merge Requests</h2><div class=\"mr-actions\">"
      if manager {
        b <+
          "<a href=\"\{repo_link(scope.repo)}/settings/branches\">Branch protection</a>"
      }
      if contributor {
        b <+
          "<a class=\"button-link\" href=\"\{base}/new\">New merge request</a>"
      }
      b <+
        "</div></div><nav class=\"mr-tabs\" aria-label=\"Merge request status\">"
      for value in ["open", "merged", "closed"] {
        b <+ "<a href=\"\{base}?status=\{value}\""
        if value == status {
          b <+ " aria-current=\"page\""
        }
        b <+ ">\{value}</a>"
      }
      b <+ "</nav><ul class=\"mr-list\">"
      for i, mr in rows {
        if i < 50 {
          b <+
            "<li><div class=\"mr-list-title\"><a href=\"\{base}/\{mr.number.to_string()}\">\{mr.title}</a><span class=\"mr-state\" data-state=\"\{mr.status}\">\{merge_status(mr)}</span></div><p class=\"muted\">!\{mr.number.to_string()} by \{mr.author} <span class=\"path\">\{mr.source}</span> into <span class=\"path\">\{mr.target}</span></p></li>"
        }
      }
      if rows.is_empty() {
        b <+ "<li class=\"muted\">No \{status} merge requests.</li>"
      }
      b <+ "</ul><nav class=\"mr-actions\" aria-label=\"Pagination\">"
      if page > 1L {
        b <+
          "<a href=\"\{base}?status=\{status}&amp;page=\{(page - 1L).to_string()}\">Previous</a>"
      }
      if rows.length() > 50 {
        b <+
          "<a href=\"\{base}?status=\{status}&amp;page=\{(page + 1L).to_string()}\">Next</a>"
      }
      b <+ "</nav>"
    }),
    head_end=repository_assets_head(assets),
    current_user=Some(user),
  )
}

///|
fn render_merge_new(
  assets : Map[String, String],
  user : CurrentUser,
  scope : RepositoryScope,
  branches : Array[String],
  default_branch : String,
  csrf : String,
  form : Map[String, String],
  error : String?,
) -> @moonback.Html {
  let base = "\{repo_link(scope.repo)}/merge-requests"
  layout(
    "New merge request",
    assets,
    Html(b => {
      b <+
        "<a href=\"\{base}\">\{scope.repo.path()} / Merge Requests</a><h1>New merge request</h1>"
      if error is Some(error) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{error}</p>"
      }
      if branches.length() < 2 {
        b <+
          "<p class=\"muted\">This repository needs two branches with commits.</p>"
      } else {
        b <+
          "<form class=\"form-stack mr-form\" method=\"post\" action=\"\{base}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><div class=\"mr-branch-fields\">"
        for field in ["source", "target"] {
          let selected = form
            .get(field)
            .unwrap_or(
              if field == "target" {
                default_branch
              } else {
                branches
                .filter(branch => branch != default_branch)
                .get(0)
                .unwrap_or(branches[0])
              },
            )
          b <+
            "<label class=\"field\"><span>\{if field == "source" { "Source branch" } else { "Target branch" }}</span><select aria-label=\"\{if field == "source" { "Source branch" } else { "Target branch" }}\" name=\"\{field}\" required>"
          for branch in branches {
            b <+ "<option value=\"\{branch}\""
            if branch == selected {
              b <+ " selected"
            }
            b <+ ">\{branch}</option>"
          }
          b <+ "</select></label>"
        }
        b <+
          "</div><label class=\"field\"><span>Title</span><input name=\"title\" maxlength=\"200\" required value=\"\{form.get("title").unwrap_or("")}\"></label><label class=\"field\"><span>Description</span><textarea aria-label=\"Description\" name=\"description\" rows=\"7\" maxlength=\"20000\">\{form.get("description").unwrap_or("")}</textarea></label><label class=\"field\"><span>Related issue number (optional)</span><input type=\"number\" min=\"1\" name=\"issue\" value=\"\{form.get("issue").unwrap_or("")}\"></label><label class=\"mr-checkbox\"><input type=\"checkbox\" name=\"draft\""
        if form.get("draft") == Some("on") {
          b <+ " checked"
        }
        b <+
          "><span>Draft</span></label><div class=\"mr-actions\"><button type=\"submit\">Create merge request</button><a href=\"\{base}\">Cancel</a></div></form>"
      }
    }),
    current_user=Some(user),
  )
}

///|
fn render_merge_detail(
  assets : Map[String, String],
  user : CurrentUser,
  scope : RepositoryScope,
  mr : MergeRequest,
  revision : MergeRevision?,
  tab : String,
  activity : Array[DbRow],
  page : Int64,
  commits : Array[CommitInfo],
  patch : String,
  diff_error : String,
  blocker : String,
  approved : Int64,
  required : Int64,
  contributor : Bool,
  manager : Bool,
  csrf : String,
  clone : String?,
) -> @moonback.Html {
  let base = "\{repo_link(scope.repo)}/merge-requests/\{mr.number}"
  let version = revision.map(value => value.version).unwrap_or(0L)
  let busy = mr.job_status == "pending" || mr.job_status == "running"
  let editable = contributor &&
    (user.id == mr.author_id || manager) &&
    mr.status != "merged" &&
    !busy
  layout(
    "!\{mr.number} \{mr.title}",
    assets,
    Html(b => {
      b <+
        "\{render_repo_nav(scope.repo, mr.target, clone)}<div class=\"mr-page-heading\"><h2 class=\"mr-title\">\{mr.title} <span class=\"muted\">!\{mr.number.to_string()}</span></h2><span class=\"mr-state\" data-state=\"\{mr.status}\">\{merge_status(mr)}</span></div><p class=\"mr-branch-summary\">\{mr.author} wants to merge <code>\{mr.source}</code> into <code>\{mr.target}</code></p>"
      if editable {
        b <+ "<div class=\"mr-actions\">"
        if mr.status == "open" {
          b <+
            "\{merge_action(base, csrf, if mr.draft { "ready" } else { "draft" }, if mr.draft { "Mark ready" } else { "Mark draft" }, version, edit_version=mr.edit_version)}\{merge_action(base, csrf, "close", "Close", version, edit_version=mr.edit_version)}"
        } else {
          b <+
            "\{merge_action(base, csrf, "reopen", "Reopen", version, edit_version=mr.edit_version)}"
        }
        b <+ "</div>"
      }
      b <+ "<nav class=\"mr-tabs\" aria-label=\"Merge request views\">"
      for value in ["discussion", "commits", "changes"] {
        b <+
          "<a href=\"\{base}?tab=\{value}&amp;version=\{version.to_string()}\""
        if value == tab {
          b <+ " aria-current=\"page\""
        }
        b <+
          ">\{match value { "discussion" => "Discussion"; "commits" => "Commits"; _ => "Changes" }}</a>"
      }
      b <+ "</nav>"
      if mr.version > 0L {
        b <+
          "<form class=\"mr-version-form\" method=\"get\"><input type=\"hidden\" name=\"tab\" value=\"\{tab}\"><label for=\"mr-version\">Version</label><input id=\"mr-version\" type=\"number\" name=\"version\" min=\"1\" max=\"\{mr.version.to_string()}\" value=\"\{version.to_string()}\"><button type=\"submit\">View</button><a href=\"\{base}?tab=\{tab}\">Latest (\{mr.version.to_string()})</a></form>"
      }
      if version != mr.version {
        b <+
          "<p class=\"settings-notice\" role=\"status\">Viewing an older version. Reviews apply only to the latest version.</p>"
      }
      if revision is Some(revision) {
        b <+
          "<p class=\"muted mr-shas\"><span>Source <code>\{revision.source_sha[:12].to_owned()}</code></span><span>Target <code>\{revision.target_sha[:12].to_owned()}</code></span></p>"
      }
      if tab == "discussion" {
        if mr.issue_number > 0L {
          b <+
            "<p>Related issue <a href=\"\{repo_link(scope.repo)}/issues/\{mr.issue_number.to_string()}\">#\{mr.issue_number.to_string()}</a></p>"
        }
        if !mr.description.is_empty() {
          b <+ "<div class=\"mr-description\">\{mr.description}</div>"
        }
        if editable {
          b <+
            "<details class=\"mr-edit\"><summary>Edit title and description</summary><form class=\"form-stack mr-form\" method=\"post\" action=\"\{base}/edit\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"edit_version\" value=\"\{mr.edit_version.to_string()}\"><label class=\"field\"><span>Title</span><input name=\"title\" required maxlength=\"200\" value=\"\{mr.title}\"></label><label class=\"field\"><span>Description</span><textarea aria-label=\"Description\" name=\"description\" rows=\"5\" maxlength=\"20000\">\{mr.description}</textarea></label><button type=\"submit\">Save changes</button></form></details>"
        }
        b <+ "<ol class=\"mr-timeline\">"
        for i, item in activity {
          if i < 50 {
            let actor : String = item.get_name("actor")
            let kind : String = item.get_name("kind")
            let body : String = item.get_name("body")
            let date : String = item.get_name("created_at")
            let item_version : Int64 = item.get_name("version")
            b <+
              "<li><div class=\"mr-event-heading\"><strong>\{actor}</strong><span>\{kind.replace_all(old="_", new=" ")}</span><time>\{date}</time>"
            if item_version > 0L {
              b <+
                "<a href=\"\{base}?tab=changes&amp;version=\{item_version.to_string()}\">v\{item_version.to_string()}</a>"
            }
            if item_version != mr.version &&
              (kind == "approved" || kind == "changes_requested") {
              b <+ "<span class=\"muted\">Outdated</span>"
            }
            b <+ "</div>"
            if !body.is_empty() {
              b <+ "<p class=\"mr-comment\">\{body}</p>"
            }
            b <+ "</li>"
          }
        }
        b <+
          "</ol><nav class=\"mr-actions\" aria-label=\"Discussion pagination\">"
        if page > 1L {
          b <+
            "<a href=\"\{base}?page=\{(page - 1L).to_string()}\">Newer activity</a>"
        }
        if activity.length() > 50 {
          b <+
            "<a href=\"\{base}?page=\{(page + 1L).to_string()}\">Older activity</a>"
        }
        b <+ "</nav>"
        if contributor && version == mr.version && version > 0L {
          b <+
            "<form class=\"form-stack mr-form mr-review-form\" method=\"post\" action=\"\{base}/review\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{version.to_string()}\"><label class=\"field\"><span>Comment</span><textarea aria-label=\"Comment\" name=\"body\" rows=\"4\" maxlength=\"20000\"></textarea></label><div class=\"mr-review-actions\"><label class=\"field\"><span>Review</span><select aria-label=\"Review\" name=\"decision\"><option value=\"comment\">Comment</option>"
          if user.id != mr.author_id &&
            mr.status == "open" &&
            !mr.draft &&
            !busy {
            b <+
              "<option value=\"approved\">Approve</option><option value=\"changes_requested\">Request changes</option><option value=\"withdrawn\">Withdraw review</option>"
          }
          b <+
            "</select></label><button type=\"submit\">Submit review</button></div></form>"
        }
      } else if tab == "commits" {
        b <+ "<ul class=\"mr-list\">"
        for commit in commits {
          b <+
            "<li><a href=\"\{repo_link(scope.repo)}/commit/\{commit.hash}\">\{commit.subject}</a><p class=\"muted\"><code>\{commit.hash[:12].to_owned()}</code> \{commit.author} · \{commit.date}</p></li>"
        }
        if commits.is_empty() {
          b <+ "<li class=\"muted\">No new commits.</li>"
        }
        b <+ "</ul>"
        if commits.length() == 100 {
          b <+ "<p class=\"muted\">Showing the first 100 commits.</p>"
        }
      } else if !diff_error.is_empty() {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{diff_error}</p>"
      } else if patch.is_empty() {
        b <+ "<p class=\"muted\">No file changes.</p>"
      } else {
        b <+
          "<moonhub-commit-diff><pre data-patch>\{patch}</pre></moonhub-commit-diff>"
      }
      b <+
        "<section class=\"mr-merge-panel\" aria-label=\"Merge status\"><h3>Merge status</h3>"
      if mr.status == "merged" {
        b <+
          "<p>Merged as <a class=\"path\" href=\"\{repo_link(scope.repo)}/commit/\{mr.merged_sha}\">\{mr.merged_sha}</a></p>"
      } else if busy {
        b <+ "<p role=\"status\">Merge queued or running.</p>"
      } else {
        b <+
          "<p>\{approved.to_string()} approvals · \{required.to_string()} required</p>"
        if !mr.job_error.is_empty() {
          b <+ "<p class=\"flash-error\" role=\"alert\">\{mr.job_error}</p>"
        }
        if !blocker.is_empty() {
          b <+ "<p role=\"status\">\{blocker}</p>"
        } else {
          b <+ "<p class=\"settings-success\">No conflicts. Ready to merge.</p>"
        }
        if manager && blocker.is_empty() && version == mr.version {
          b <+ "\{merge_action(base, csrf, "merge", "Merge request", version)}"
        }
        if !manager && mr.status == "open" {
          b <+
            "<p class=\"muted\">A team owner or administrator can merge this request.</p>"
        }
      }
      b <+ "</section>"
    }),
    head_end=repository_assets_head(assets, code_view=tab == "changes"),
    current_user=Some(user),
  )
}

///|
fn render_branch_rules(
  assets : Map[String, String],
  user : CurrentUser,
  scope : RepositoryScope,
  rules : Array[DbRow],
  csrf : String,
) -> @moonback.Html {
  let base = "\{repo_link(scope.repo)}/settings/branches"
  layout(
    "Branch protection",
    assets,
    Html(b => {
      b <+
        "<a href=\"\{repo_link(scope.repo)}/merge-requests\">\{scope.repo.path()} / Merge Requests</a><h1>Branch protection</h1><ul class=\"mr-list\">"
      for rule in rules {
        let branch : String = rule.get_name("branch")
        let approvals : Int64 = rule.get_name("required_approvals")
        b <+
          "<li class=\"mr-rule\"><div><strong class=\"path\">\{branch}</strong><p class=\"muted\">Merge requests only · \{approvals.to_string()} approvals required</p></div><form method=\"post\" action=\"\{base}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"branch\" value=\"\{branch}\"><button type=\"submit\" name=\"action\" value=\"remove\">Remove protection</button></form></li>"
      }
      if rules.is_empty() {
        b <+ "<li class=\"muted\">No protected branches.</li>"
      }
      b <+
        "</ul><form class=\"form-stack mr-form\" method=\"post\" action=\"\{base}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label class=\"field\"><span>Branch name</span><input name=\"branch\" required maxlength=\"200\" spellcheck=\"false\"></label><label class=\"field\"><span>Required approvals</span><select aria-label=\"Required approvals\" name=\"approvals\"><option value=\"1\">1 approval from another team member</option><option value=\"0\">No approval required</option></select></label><button type=\"submit\">Protect branch</button></form>"
    }),
    current_user=Some(user),
  )
}
