///|
fn merge_action(
  base : String,
  csrf : String,
  action : String,
  label : String,
  version : Int64,
  edit_version~ : Int64 = 1L,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<form method=\"post\" action=\"\{base}/\{action}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{version.to_string()}\"><input type=\"hidden\" name=\"edit_version\" value=\"\{edit_version.to_string()}\"><button type=\"submit\">\{label}</button></form>"
  })
}

///|
fn render_merge_list(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  rows : Array[@collaboration.MergeRequest],
  status : String,
  page : Int64,
  contributor : Bool,
  manager : Bool,
  clone : String?,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(scope.repo)}/merge-requests"
  @web_ui.layout(
    "Merge Requests",
    assets,
    Html(b => {
      b <+
        "\{@web_ui.render_repo_nav(scope.repo, "HEAD", clone)}<div class=\"mr-page-heading\"><h2>Merge Requests</h2><div class=\"mr-actions\">"
      if manager {
        b <+
          "<a href=\"\{@web_ui.repo_link(scope.repo)}/settings/branches\">Branch protection</a>"
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
            "<li><div class=\"mr-list-title\"><a href=\"\{base}/\{mr.number.to_string()}\"><span class=\"ui-icon\" data-icon=\"git-pull-request\" aria-hidden=\"true\"></span>\{mr.title}</a><span class=\"mr-state\" data-state=\"\{@web_ui.merge_status(mr).to_lower()}\">\{@web_ui.merge_status(mr)}</span></div><p class=\"muted\">!\{mr.number.to_string()} by \{mr.author} <span class=\"path\">\{mr.source}</span> into <span class=\"path\">\{mr.target}</span></p></li>"
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
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(
      scope.repo,
      "merge-requests",
      manager,
    ),
  )
}

///|
fn render_merge_new(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  branches : Array[String],
  default_branch : String,
  csrf : String,
  form : Map[String, String],
  error : String?,
  manager~ : Bool = false,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(scope.repo)}/merge-requests"
  @web_ui.layout(
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
    navigation=@web_ui.RepositoryNavigation(
      scope.repo,
      "merge-requests",
      manager,
    ),
  )
}

///|
fn render_merge_detail(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  mr : @collaboration.MergeRequest,
  revision : @collaboration.MergeRevision?,
  tab : String,
  activity : Array[@collaboration.MergeActivity],
  page : Int64,
  commits : Array[@gitops.CommitInfo],
  patch : String,
  diff_error : String,
  blocker : String,
  approved : Int64,
  required : Int64,
  contributor : Bool,
  manager : Bool,
  csrf : String,
  clone : String?,
  checks : Array[@collaboration.MergeCheck],
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(scope.repo)}/merge-requests/\{mr.number}"
  let version = revision.map(value => value.version).unwrap_or(0L)
  let busy = mr.job_status == "pending" || mr.job_status == "running"
  let editable = contributor &&
    (user.id == mr.author_id || manager) &&
    mr.status != "merged" &&
    !busy
  @web_ui.layout(
    "!\{mr.number} \{mr.title}",
    assets,
    Html(b => {
      b <+
        "\{@web_ui.render_repo_nav(scope.repo, mr.target, clone)}<div class=\"mr-page-heading\"><h2 class=\"mr-title\">\{mr.title} <span class=\"muted\">!\{mr.number.to_string()}</span></h2><span class=\"mr-state\" data-state=\"\{@web_ui.merge_status(mr).to_lower()}\">\{@web_ui.merge_status(mr)}</span></div><p class=\"mr-branch-summary\">\{mr.author} wants to merge <code>\{mr.source}</code> into <code>\{mr.target}</code></p>"
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
            "<p>Related issue <a href=\"\{@web_ui.repo_link(scope.repo)}/issues/\{mr.issue_number.to_string()}\">#\{mr.issue_number.to_string()}</a></p>"
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
            let actor = item.actor
            let kind = item.kind
            let body : String = if kind == "merge_failed" {
              @domain.merge_error_message
            } else {
              item.body
            }
            let date = item.created_at
            let item_version = item.version
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
            "<li><a href=\"\{@web_ui.repo_link(scope.repo)}/commit/\{commit.hash}\">\{commit.subject}</a><p class=\"muted\"><code>\{commit.hash[:12].to_owned()}</code> \{commit.author} · \{commit.date}</p></li>"
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
      if !checks.is_empty() {
        b <+
          "<section class=\"mr-merge-panel\" aria-label=\"Pipeline checks\"><h3>Pipeline checks</h3><ul class=\"mr-list\">"
        for check in checks {
          let state = if check.state == "completed" {
            check.conclusion
          } else {
            check.state
          }
          let label = match state {
            "awaiting_approval" => "Awaiting manager approval"
            "pending" => "Preparing"
            "queued" => "Queued"
            "running" => "Running"
            "success" => "Passed"
            "failure" => "Failed"
            "cancelled" => "Cancelled"
            "timed_out" => "Timed out"
            "lost" => "Runner lost"
            "skipped" => "Skipped"
            _ => "Could not prepare checks"
          }
          b <+
            "<li><div class=\"mr-actions\"><strong class=\"path\">\{check.workflow_path}</strong><span class=\"mr-state\" data-state=\"\{state}\">\{label}</span>"
          if check.run_number is Some(number) {
            b <+
              "<a href=\"\{@web_ui.repo_link(scope.repo)}/pipelines/\{number.to_string()}\">Run #\{number.to_string()} and logs</a>"
          }
          b <+ "</div>"
          if !check.error.is_empty() {
            b <+ "<p class=\"flash-error\" role=\"alert\">\{check.error}</p>"
          }
          b <+ "</li>"
        }
        b <+ "</ul><p><a href=\"\{base}?tab=\{tab}\">Refresh checks</a></p>"
        if manager &&
          mr.status == "open" &&
          !mr.draft &&
          !busy &&
          version == mr.version &&
          checks
          .iter()
          .any(check => {
            check.state == "awaiting_approval" || check.state == "error"
          }) {
          b <+
            "\{merge_action(base, csrf, "approve-checks", "Approve and run checks", version)}"
        }
        b <+ "</section>"
      }
      b <+
        "<section class=\"mr-merge-panel\" aria-label=\"Merge status\"><h3>Merge status</h3>"
      if mr.status == "merged" {
        b <+
          "<p>Merged as <a class=\"path\" href=\"\{@web_ui.repo_link(scope.repo)}/commit/\{mr.merged_sha}\">\{mr.merged_sha}</a></p>"
      } else if busy {
        b <+ "<p role=\"status\">Merge queued or running.</p>"
      } else {
        b <+
          "<p>\{approved.to_string()} approvals · \{required.to_string()} required</p>"
        if !mr.job_error.is_empty() {
          b <+
            "<p class=\"flash-error\" role=\"alert\">\{@domain.public_merge_job_error(mr.job_error)}</p>"
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
    head_end=@web_assets.repository_assets_head(
      assets,
      code_view=tab == "changes",
    ),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(
      scope.repo,
      "merge-requests",
      manager,
    ),
  )
}

///|
fn render_branch_rules(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  rules : Array[@collaboration.BranchRule],
  csrf : String,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(scope.repo)}/settings/branches"
  @web_ui.layout(
    "Branch protection",
    assets,
    Html(b => {
      b <+
        "<a href=\"\{@web_ui.repo_link(scope.repo)}/merge-requests\">\{scope.repo.path()} / Merge Requests</a><h1>Branch protection</h1><ul class=\"mr-list\">"
      for rule in rules {
        let branch = rule.branch
        let approvals = rule.required_approvals
        b <+
          "<li class=\"mr-rule\"><div><strong class=\"path\">\{branch}</strong><p class=\"muted\">Merge requests only · \{approvals.to_string()} approvals required</p></div>"
        for path in rule.checks {
          b <+ "<p class=\"path\">\{path}</p>"
        }
        b <+
          "<details class=\"mr-edit\"><summary>Edit rule</summary>\{render_branch_rule_form(base, csrf, Some(rule))}</details><form method=\"post\" action=\"\{base}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"branch\" value=\"\{branch}\"><button type=\"submit\" name=\"action\" value=\"remove\">Remove protection</button></form></li>"
      }
      if rules.is_empty() {
        b <+ "<li class=\"muted\">No protected branches.</li>"
      }
      b <+ "</ul>\{render_branch_rule_form(base, csrf, None)}"
    }),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(scope.repo, "settings", true),
  )
}

///|
fn render_branch_rule_form(
  base : String,
  csrf : String,
  rule : @collaboration.BranchRule?,
) -> @moonback.Html {
  let branch = rule.map(rule => rule.branch).unwrap_or("")
  let approvals = rule.map(rule => rule.required_approvals).unwrap_or(1L)
  let checks = rule.map(rule => rule.checks.join("\n")).unwrap_or("")
  Html(b => {
    b <+
      "<form class=\"form-stack mr-form\" method=\"post\" action=\"\{base}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label class=\"field\"><span>Branch name</span><input name=\"branch\" value=\"\{branch}\" required maxlength=\"200\" spellcheck=\"false\""
    if rule is Some(_) {
      b <+ " readonly"
    }
    b <+
      "></label><label class=\"field\"><span>Required approvals</span><select name=\"approvals\" aria-label=\"Required approvals\"><option value=\"1\""
    if approvals == 1L {
      b <+ " selected"
    }
    b <+ ">1 approval from another team member</option><option value=\"0\""
    if approvals == 0L {
      b <+ " selected"
    }
    b <+
      ">No approval required</option></select></label><label class=\"field\"><span>Required workflows (one path per line)</span><textarea name=\"checks\" aria-label=\"Required workflows (one path per line)\" rows=\"3\" maxlength=\"4096\" spellcheck=\"false\" placeholder=\".github/workflows/build.yml\">\{checks}</textarea><small>Read from the target branch; run against the merged source and target.</small></label><button type=\"submit\">\{if rule is Some(_) { "Save rule" } else { "Protect branch" }}</button></form>"
  })
}
