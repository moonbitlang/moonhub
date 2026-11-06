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
  metadata : Map[Int64, @collaboration.MergeListMeta],
  query : String,
  mine : String,
  status : String,
  page : Int64,
  contributor : Bool,
  manager : Bool,
  _clone : String?,
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(scope.repo)}/merge-requests"
  @web_ui.layout(
    "Merge Requests",
    assets,
    Html(b => {
      b <+
        "<div class=\"mr-page-heading\"><div><h1>Merge requests</h1><p class=\"page-subtitle\">\{scope.repo.path()}</p></div><div class=\"mr-actions\">"
      if contributor {
        b <+
          "<a class=\"button-link\" href=\"\{base}/new\">New merge request</a>"
      }
      b <+
        "</div></div><nav class=\"page-tabs\" aria-label=\"Merge request status\">"
      for value in ["open", "merged", "closed"] {
        b <+
          "<a href=\"\{base}?status=\{value}&amp;q=\{@web_context.url_escape_path(query)}&amp;mine=\{mine}\""
        if value == status {
          b <+ " aria-current=\"page\""
        }
        b <+ ">\{value}</a>"
      }
      b <+
        "</nav><form class=\"list-filters\" method=\"get\"><input type=\"hidden\" name=\"status\" value=\"\{status}\"><label class=\"field\"><span>Search titles</span><input type=\"search\" name=\"q\" value=\"\{query}\" maxlength=\"200\"></label><label class=\"field\"><span>View</span><select name=\"mine\">"
      for
        (key, label) in [
          ("all", "All merge requests"),
          ("author", "Authored by me"),
          ("reviews", "Needs my review"),
        ] {
        b <+ "<option value=\"\{key}\""
        if key == mine {
          b <+ " selected"
        }
        b <+ ">\{label}</option>"
      }
      b <+
        "</select></label><button class=\"secondary-button\" type=\"submit\">Filter</button><a href=\"\{base}?status=\{status}\">Reset</a></form><ul class=\"mr-list compact-records\">"
      for i, mr in rows {
        if i < 50 {
          let meta = metadata.get(mr.id)
          b <+
            "<li><div class=\"mr-list-title\"><a href=\"\{base}/\{mr.number.to_string()}\"><span class=\"ui-icon\" data-icon=\"git-pull-request\" aria-hidden=\"true\"></span>\{mr.title}</a><span class=\"mr-state\" data-state=\"\{@web_ui.merge_status(mr).to_lower()}\">\{@web_ui.merge_status(mr)}</span></div><p class=\"muted\">!\{mr.number.to_string()} by \{mr.author} <span class=\"path\">\{mr.source}</span> into <span class=\"path\">\{mr.target}</span></p>"
          if meta is Some(meta) {
            b <+
              "<div class=\"record-meta\"><span>\{meta.approvals.to_string()} approvals</span><span>\{meta.requested.to_string()} review requests pending</span>"
            if !meta.checks.is_empty() {
              b <+
                "<span class=\"mr-state\" data-state=\"\{meta.checks}\">CI \{if meta.checks == "success" { "passed" } else if meta.checks == "failure" { "failed" } else { "pending" }}</span>"
            }
            b <+
              "<time data-relative-time datetime=\"\{meta.updated}Z\" title=\"\{meta.updated} UTC\">\{meta.updated} UTC</time></div>"
          }
          b <+ "</li>"
        }
      }
      if rows.is_empty() {
        b <+
          "<li class=\"muted\">No matching merge requests. Change your filters or create a new request.</li>"
      }
      b <+ "</ul><nav class=\"mr-actions\" aria-label=\"Pagination\">"
      if page > 1L {
        b <+
          "<a href=\"\{base}?status=\{status}&amp;q=\{@web_context.url_escape_path(query)}&amp;mine=\{mine}&amp;page=\{(page - 1L).to_string()}\">Previous</a>"
      }
      if rows.length() > 50 {
        b <+
          "<a href=\"\{base}?status=\{status}&amp;q=\{@web_context.url_escape_path(query)}&amp;mine=\{mine}&amp;page=\{(page + 1L).to_string()}\">Next</a>"
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
  let default_branch = if branches.contains(default_branch) {
    default_branch
  } else if branches.contains("main") {
    "main"
  } else if branches.contains("master") {
    "master"
  } else {
    branches.get(0).unwrap_or("")
  }
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
          "<form class=\"form-stack mr-form\" method=\"post\" action=\"\{base}\" data-branch-comparison><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><div class=\"mr-branch-fields\">"
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
          "</div><p class=\"settings-notice\" data-branch-warning hidden role=\"status\">Source and target must be different branches.</p><label class=\"field\"><span>Title</span><input name=\"title\" maxlength=\"200\" required value=\"\{form.get("title").unwrap_or("")}\"></label><label class=\"field\"><span>Description</span><textarea aria-label=\"Description\" name=\"description\" rows=\"7\" maxlength=\"20000\">\{form.get("description").unwrap_or("")}</textarea></label><label class=\"field\"><span>Related issue number (optional)</span><input type=\"number\" min=\"1\" name=\"issue\" value=\"\{form.get("issue").unwrap_or("")}\"></label><label class=\"mr-checkbox\"><input type=\"checkbox\" name=\"draft\""
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
fn render_merge_target_form(
  base : String,
  csrf : String,
  branches : Array[String],
  source : String,
  target : String,
  edit_version : String,
  error : String?,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<form class=\"form-stack mr-form\" method=\"post\" action=\"\{base}/retarget\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"edit_version\" value=\"\{edit_version}\">"
    if error is Some(message) {
      b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
    }
    b <+
      "<label class=\"field\"><span>Target branch</span><select name=\"target\" required aria-describedby=\"mr-target-notice\">"
    if !branches.contains(target) && !target.is_empty() {
      b <+
        "<option value=\"\{target}\" selected>\{target} (unavailable)</option>"
    }
    for branch in branches {
      if branch != source {
        b <+ "<option value=\"\{branch}\""
        if branch == target {
          b <+ " selected"
        }
        b <+ ">\{branch}</option>"
      }
    }
    b <+
      "</select></label><p class=\"muted\" id=\"mr-target-notice\">Changing the target creates a new version. Existing reviews and check results will not apply; checks run again under the new target branch rules.</p><button class=\"secondary-button\" type=\"submit\">Change target branch</button></form>"
  })
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
  discussions : Array[@collaboration.MergeDiscussion],
  discussion_filter : String,
  selected_discussion : Int64?,
  discussion_page : Int64,
  unresolved : Int64,
  commits : Array[@gitops.CommitInfo],
  commit_page : Int64,
  comparison : @gitops.RevisionComparison?,
  patch : String,
  diff_error : String,
  blocker : String,
  approved : Int64,
  required : Int64,
  allow_self_approval : Bool,
  contributor : Bool,
  manager : Bool,
  csrf : String,
  _clone : String?,
  checks : Array[@collaboration.MergeCheck],
  reviewers : Array[@collaboration.ReviewRequest],
  candidates : Array[@collaboration.IssueAssignee],
  subscription : @collaboration.ThreadSubscription,
  notification_csrf : String,
  branches~ : Array[String] = [],
) -> @moonback.Html {
  let base = "\{@web_ui.repo_link(scope.repo)}/merge-requests/\{mr.number}"
  let version = revision.map(value => value.version).unwrap_or(0L)
  let selected_commit : @gitops.CommitInfo? = match comparison {
    Some(value) => value.commit
    None => None
  }
  let commit_query = selected_commit
    .map(commit => "&commit=" + commit.hash)
    .unwrap_or("")
  let target = revision.map(value => value.target_branch).unwrap_or(mr.target)
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
        "<a class=\"back-link\" href=\"\{@web_ui.repo_link(scope.repo)}/merge-requests\">Merge requests</a><div class=\"mr-page-heading\"><h1 class=\"mr-title\">\{mr.title} <span class=\"muted\">!\{mr.number.to_string()}</span></h1><span class=\"mr-state\" data-state=\"\{@web_ui.merge_status(mr).to_lower()}\">\{@web_ui.merge_status(mr)}</span></div><p class=\"mr-branch-summary\">\{mr.author} wants to merge <code>\{mr.source}</code> into <code>\{target}</code></p>"
      if editable {
        b <+
          "<details class=\"secondary-details mr-more-actions\"><summary>More actions</summary><div class=\"mr-actions\">"
        if mr.status == "open" {
          b <+
            "\{merge_action(base, csrf, if mr.draft { "ready" } else { "draft" }, if mr.draft { "Mark ready" } else { "Mark draft" }, version, edit_version=mr.edit_version)}\{merge_action(base, csrf, "close", "Close", version, edit_version=mr.edit_version)}"
        } else {
          b <+
            "\{merge_action(base, csrf, "reopen", "Reopen", version, edit_version=mr.edit_version)}"
        }
        b <+ "</div>"
        if mr.status == "open" && version == mr.version {
          b <+
            "\{render_merge_target_form(base, csrf, branches, mr.source, mr.target, mr.edit_version.to_string(), None)}"
        }
        b <+ "</details>"
      }
      b <+ "<nav class=\"mr-tabs\" aria-label=\"Merge request views\">"
      for value in ["discussion", "commits", "changes"] {
        b <+
          "<a href=\"\{base}?tab=\{value}&amp;version=\{version.to_string()}\{if value == "changes" { commit_query } else { "" }}\""
        if value == tab {
          b <+ " aria-current=\"page\""
        }
        b <+
          ">\{match value { "discussion" => "Discussion"; "commits" => "Commits"; _ => "Changes" }}</a>"
      }
      b <+ "</nav>"
      if mr.version > 0L {
        b <+
          "<form class=\"mr-version-form\" method=\"get\" data-auto-submit><input type=\"hidden\" name=\"tab\" value=\"\{tab}\"><label for=\"mr-version\">Version</label><select id=\"mr-version\" name=\"version\">"
        for v = mr.version; v > 0L; v = v - 1L {
          b <+ "<option value=\"\{v.to_string()}\""
          if v == version {
            b <+ " selected"
          }
          b <+
            ">v\{v.to_string()}\{if v == mr.version { " — Latest" } else { "" }}</option>"
        }
        b <+
          "</select><button class=\"secondary-button no-js-submit\" type=\"submit\">View</button></form>"
      }
      if version != mr.version {
        b <+
          "<p class=\"settings-notice\" role=\"status\">Viewing an older version. Reviews apply only to the latest version.</p>"
      }
      if revision is Some(revision) {
        b <+
          "<details class=\"secondary-details\"><summary>Revision commits</summary><p class=\"muted mr-shas\"><span>Source <code>\{revision.source_sha[:12].to_owned()}</code></span><span>Target <code>\{revision.target_sha[:12].to_owned()}</code></span></p></details>"
      }
      b <+
        "<div class=\"mr-workspace\" data-view=\"\{tab}\"><div class=\"mr-main\">"
      if tab == "discussion" {
        if mr.issue_number > 0L {
          b <+
            "<p>Related issue <a href=\"\{@web_ui.repo_link(scope.repo)}/issues/\{mr.issue_number.to_string()}\">#\{mr.issue_number.to_string()}</a></p>"
        }
        if !mr.description.is_empty() {
          b <+
            "<section class=\"discussion-description\"><h2>Description</h2><div class=\"markdown-body\">\{@web_ui.markdown(mr.description, repo=Some(scope.repo))}</div></section>"
        }
        if editable {
          b <+
            "<details class=\"mr-edit\"><summary>Edit title and description</summary><form class=\"form-stack mr-form\" method=\"post\" action=\"\{base}/edit\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"edit_version\" value=\"\{mr.edit_version.to_string()}\"><label class=\"field\"><span>Title</span><input name=\"title\" required maxlength=\"200\" value=\"\{mr.title}\"></label><label class=\"field\"><span>Description</span><textarea aria-label=\"Description\" name=\"description\" rows=\"5\" maxlength=\"20000\">\{mr.description}</textarea></label><button type=\"submit\">Save changes</button></form></details>"
        }
        b <+
          "<section class=\"mr-discussions\" aria-label=\"Comment discussions\"><h2>Discussions <span class=\"muted\">\{unresolved.to_string()} unresolved</span></h2><nav class=\"mr-actions\" aria-label=\"Discussion filters\">"
        for filter in ["all", "unresolved", "resolved"] {
          b <+
            "<a href=\"\{base}?tab=discussion&amp;version=\{version.to_string()}&amp;filter=\{filter}\""
          if selected_discussion is None && filter == discussion_filter {
            b <+ " aria-current=\"page\""
          }
          b <+
            ">\{match filter { "all" => "All"; "unresolved" => "Unresolved"; _ => "Resolved" }}</a>"
        }
        b <+ "</nav>"
        if discussions.is_empty() {
          b <+ "<p class=\"muted\">No discussions in this view.</p>"
        }
        for i, discussion in discussions {
          if i < 50 {
            b <+
              "\{render_merge_discussion(scope.repo, base, csrf, user, discussion, contributor, manager, selected_discussion is Some(_), discussion_page)}"
          }
        }
        b <+ "<nav class=\"mr-actions\" aria-label=\"Thread pagination\">"
        let selection = match selected_discussion {
          Some(id) => "discussion=\{id}"
          None => "filter=\{discussion_filter}"
        }
        if discussion_page > 1L {
          b <+
            "<a href=\"\{base}?version=\{version.to_string()}&amp;\{selection}&amp;discussion_page=\{(discussion_page - 1L).to_string()}\">Previous page</a>"
        }
        let has_more = match selected_discussion {
          Some(_) => discussions[0].reply_count > discussion_page * 50L
          None => discussions.length() > 50
        }
        if has_more {
          b <+
            "<a href=\"\{base}?version=\{version.to_string()}&amp;\{selection}&amp;discussion_page=\{(discussion_page + 1L).to_string()}\">Next page</a>"
        }
        b <+
          "</nav></section><details class=\"secondary-details\"><summary>Activity history</summary><ol class=\"mr-timeline\">"
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
            if item.discussion_id is Some(discussion) {
              b <+ "<a href=\"\{base}?discussion=\{discussion.to_string()}"
              if kind == "comment" ||
                kind == "comment_deleted" ||
                item.id == discussion {
                b <+
                  "&amp;comment=\{item.id.to_string()}#comment-\{item.id.to_string()}"
              } else {
                b <+ "#discussion-\{discussion.to_string()}"
              }
              b <+ "\">View discussion</a>"
            }
            b <+ "</div>"
            if !body.is_empty() {
              b <+
                "<div class=\"mr-comment markdown-body\">\{@web_ui.markdown(body, repo=Some(scope.repo))}</div>"
            }
            b <+ "</li>"
          }
        }
        b <+
          "</ol><nav class=\"mr-actions\" aria-label=\"Discussion pagination\">"
        if page > 1L {
          b <+
            "<a href=\"\{base}?tab=discussion&amp;version=\{version.to_string()}&amp;page=\{(page - 1L).to_string()}\">Newer activity</a>"
        }
        if activity.length() > 50 {
          b <+
            "<a href=\"\{base}?tab=discussion&amp;version=\{version.to_string()}&amp;page=\{(page + 1L).to_string()}\">Older activity</a>"
        }
        b <+ "</nav></details>"
      } else {
        if tab == "changes" {
          b <+
            "<form class=\"mr-version-form mr-comparison-form\" method=\"get\" data-auto-submit><input type=\"hidden\" name=\"tab\" value=\"changes\"><input type=\"hidden\" name=\"version\" value=\"\{version.to_string()}\"><input type=\"hidden\" name=\"commit_page\" value=\"\{commit_page.to_string()}\"><label for=\"mr-commit\">Changes</label><select id=\"mr-commit\" name=\"commit\"><option value=\"\">All changes</option>"
          if selected_commit is Some(selected) &&
            !commits
            .iter()
            .take(100)
            .any(commit => commit.hash == selected.hash) {
            b <+
              "<option value=\"\{selected.hash}\" selected>\{selected.hash[:12].to_owned()} · \{selected.subject}</option>"
          }
          for i, commit in commits {
            if i < 100 {
              b <+ "<option value=\"\{commit.hash}\""
              if selected_commit is Some(selected) &&
                selected.hash == commit.hash {
                b <+ " selected"
              }
              b <+
                ">\{commit.hash[:12].to_owned()} · \{commit.subject}</option>"
            }
          }
          b <+
            "</select><button class=\"secondary-button no-js-submit\" type=\"submit\">View</button></form>"
          if comparison is Some(comparison) {
            if selected_commit is Some(commit) {
              b <+
                "<h2 class=\"mr-commit-title\">\{commit.subject}</h2><p class=\"muted\">\{commit.author} · \{commit.date} · <a href=\"\{@web_ui.repo_link(scope.repo)}/commit/\{commit.hash}\">Commit details</a></p><p class=\"muted mr-shas\">\{if comparison.parent_count > 1 { "Merge commit compared with first parent" } else if comparison.parent_count == 0 { "Root commit compared with empty tree" } else { "Compared with parent" }} <code>\{comparison.base_sha[:12].to_owned()}</code> → <code>\{comparison.head_sha[:12].to_owned()}</code></p>"
              b <+
                "<p class=\"muted\">Showing one commit in v\{version.to_string()}. Reviews apply to the entire MR version. <a href=\"\{base}?tab=changes&amp;version=\{version.to_string()}\">View all changes</a></p>"
            } else {
              b <+
                "<p class=\"muted mr-shas\">All changes in v\{version.to_string()}: merge base <code>\{comparison.base_sha[:12].to_owned()}</code> → source <code>\{comparison.head_sha[:12].to_owned()}</code></p>"
            }
          }
        } else {
          b <+ "<ul class=\"mr-list\">"
          for i, commit in commits {
            if i < 100 {
              b <+
                "<li><a href=\"\{base}?tab=changes&amp;version=\{version.to_string()}&amp;commit=\{commit.hash}&amp;commit_page=\{commit_page.to_string()}\">\{commit.subject}</a><p class=\"muted\"><code>\{commit.hash[:12].to_owned()}</code> \{commit.author} · \{commit.date}</p></li>"
            }
          }
          if commits.is_empty() {
            b <+ "<li class=\"muted\">No commits on this page.</li>"
          }
          b <+ "</ul>"
        }
        if commit_page > 1L || commits.length() > 100 {
          b <+ "<nav class=\"mr-actions\" aria-label=\"Commit pagination\">"
          if commit_page > 1L {
            b <+
              "<a href=\"\{base}?tab=\{tab}&amp;version=\{version.to_string()}&amp;commit_page=\{(commit_page - 1L).to_string()}\{commit_query}\">Newer commits</a>"
          }
          if commits.length() > 100 {
            b <+
              "<a href=\"\{base}?tab=\{tab}&amp;version=\{version.to_string()}&amp;commit_page=\{(commit_page + 1L).to_string()}\{commit_query}\">Older commits</a>"
          }
          b <+ "</nav>"
        }
        if tab == "changes" {
          if !diff_error.is_empty() {
            b <+ "<p class=\"flash-error\" role=\"alert\">\{diff_error}</p>"
          } else if patch.is_empty() {
            b <+ "<p class=\"muted\">No file changes in this comparison.</p>"
          } else {
            if comparison is Some(comparison) {
              b <+
                "<section class=\"inline-review\" aria-label=\"Code discussions\">"
              if contributor {
                b <+
                  "\{render_inline_composer(base, csrf, version.to_string(), comparison.commit.map(c => c.hash).unwrap_or(""), Map([]), None)}"
              }
              b <+ "</section>"
            }
            b <+
              "<moonhub-commit-diff id=\"diff-code\" data-inline-review><pre data-patch>\{patch}</pre>"
            for i, discussion in discussions {
              if i < 50 {
                if discussion.anchor is Some(anchor) {
                  if discussion.version == version &&
                    anchor.base_sha ==
                    comparison.map(c => c.base_sha).unwrap_or("") &&
                    anchor.head_sha ==
                    comparison.map(c => c.head_sha).unwrap_or("") &&
                    anchor.commit_sha ==
                    selected_commit.map(c => c.hash).unwrap_or("") {
                    let preview = StringBuilder()
                    for ch in discussion.root.body.iter().take(180) {
                      preview.write_char(ch)
                    }
                    b <+
                      "<a hidden data-inline-thread data-discussion=\"\{discussion.id.to_string()}\" data-preview=\"\{if discussion.root.kind == "comment_deleted" { "Comment deleted." } else { preview.to_string() }}\" data-old-path=\"\{anchor.old_path}\" data-new-path=\"\{anchor.new_path}\" data-side=\"\{anchor.side}\" data-start=\"\{anchor.start_line.to_string()}\" data-end=\"\{anchor.end_line.to_string()}\" href=\"\{base}?discussion=\{discussion.id.to_string()}#discussion-\{discussion.id.to_string()}\">#\{discussion.id.to_string()} · \{if discussion.resolved { "Resolved" } else { "Unresolved" }}</a>"
                  }
                }
              }
            }
            b <+ "</moonhub-commit-diff>"
          }
          b <+
            "<section class=\"inline-discussions\" aria-label=\"Discussions on this comparison\"><h2>Code discussions</h2>"
          if discussions.is_empty() {
            b <+
              "<p class=\"muted\">No code discussions in this comparison.</p>"
          }
          for i, discussion in discussions {
            if i < 50 {
              b <+
                "\{render_merge_discussion(scope.repo, base, csrf, user, discussion, contributor, manager, selected_discussion == Some(discussion.id), discussion_page)}"
            }
          }
          if selected_discussion is Some(id) {
            if discussion_page > 1L {
              b <+
                "<a href=\"\{base}?discussion=\{id.to_string()}&amp;discussion_page=\{(discussion_page - 1L).to_string()}#discussion-\{id.to_string()}\">Earlier replies</a>"
            }
            if discussions[0].reply_count > discussion_page * 50L {
              b <+
                "<a href=\"\{base}?discussion=\{id.to_string()}&amp;discussion_page=\{(discussion_page + 1L).to_string()}#discussion-\{id.to_string()}\">Later replies</a>"
            }
          } else {
            if discussion_page > 1L {
              b <+
                "<a href=\"\{base}?tab=changes&amp;version=\{version.to_string()}\{commit_query}&amp;discussion_page=\{(discussion_page - 1L).to_string()}\">Newer code discussions</a>"
            }
            if discussions.length() > 50 {
              b <+
                "<a href=\"\{base}?tab=changes&amp;version=\{version.to_string()}\{commit_query}&amp;discussion_page=\{(discussion_page + 1L).to_string()}\">Older code discussions</a>"
            }
          }
          b <+ "</section>"
        }
      }
      b <+
        "</div><aside class=\"mr-sidebar\" aria-label=\"Review and merge readiness\">"
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
      if user.id == mr.author_id && mr.status == "open" && !allow_self_approval {
        b <+
          "<p class=\"permission-hint\">You authored this merge request and cannot approve it yourself. \{if required > 0L { "Another team member must approve this version." } else { "You can request an independent review." }}</p>"
      }
      b <+ "</section>"
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
          b <+
            "</div><p class=\"muted\">\{if check.required { "Required for merge" } else { "Automatic workflow · optional for merge" }}</p>"
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
        "<details class=\"mr-reviewers\" data-mobile-details open aria-label=\"Requested reviewers\"><summary>Reviewers</summary>"
      if reviewers.is_empty() {
        b <+ "<p class=\"muted\">No reviewers requested yet.</p>"
      } else {
        b <+ "<ul class=\"mr-list\">"
        for reviewer in reviewers {
          b <+
            "<li><div class=\"mr-actions\"><strong>\{reviewer.display_name}</strong><span class=\"muted\">\{if reviewer.pending { "Review requested" } else { "Review submitted" }} · v\{reviewer.version.to_string()}</span>"
          if editable &&
            mr.status == "open" &&
            !mr.draft &&
            !reviewer.pending &&
            version == mr.version {
            b <+
              "<form method=\"post\" action=\"\{base}/request-review\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{version.to_string()}\"><input type=\"hidden\" name=\"reviewer\" value=\"\{reviewer.user_id.to_string()}\"><button class=\"secondary-button\" type=\"submit\">Request review again</button></form>"
          }
          b <+ "</div></li>"
        }
        b <+ "</ul>"
      }
      if editable &&
        mr.status == "open" &&
        !mr.draft &&
        version == mr.version &&
        !candidates.is_empty() {
        b <+
          "<form class=\"mr-actions reviewer-request-form\" method=\"post\" action=\"\{base}/request-review\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{version.to_string()}\"><label class=\"field\"><span>Request a reviewer</span><select aria-label=\"Request a reviewer\" name=\"reviewer\" required><option value=\"\">Choose a reviewer</option>"
        for candidate in candidates {
          b <+
            "<option value=\"\{candidate.id.to_string()}\">\{candidate.display_name} (@\{candidate.name_key})</option>"
        }
        b <+
          "</select></label><button type=\"submit\">Request review</button></form>"
      }
      b <+ "</details>"
      if contributor && version == mr.version && version > 0L {
        b <+
          "<details class=\"review-composer\" id=\"mr-review-form\"><summary>Write a comment or review</summary><form class=\"form-stack mr-form mr-review-form\" method=\"post\" action=\"\{base}/review\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{version.to_string()}\"><label class=\"field\"><span>Comment</span><textarea aria-label=\"Comment\" name=\"body\" rows=\"4\" maxlength=\"20000\"></textarea></label><div class=\"mr-review-actions\"><label class=\"field\"><span>Review</span><select aria-label=\"Review\" name=\"decision\"><option value=\"comment\">Comment</option>"
        if mr.status == "open" && !mr.draft && !busy {
          if user.id != mr.author_id || allow_self_approval {
            b <+ "<option value=\"approved\">Approve</option>"
          }
          if user.id != mr.author_id {
            b <+
              "<option value=\"changes_requested\">Request changes</option><option value=\"withdrawn\">Withdraw review</option>"
          }
        }
        b <+
          "</select></label><button type=\"submit\">Submit review</button></div></form></details>"
      }
      b <+
        "<details class=\"secondary-details\"><summary>Notification preferences</summary>\{@web_ui.render_thread_subscription(subscription, notification_csrf)}</details></aside></div>"
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
          "<li class=\"mr-rule\"><div><strong class=\"path\">\{branch}</strong><p class=\"muted\">Merge requests only · \{approvals.to_string()} approvals required · \{if rule.allow_self_approval { "Author approval allowed" } else { "Author approval disabled" }}</p></div>"
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
    b <+ ">1 approval</option><option value=\"0\""
    if approvals == 0L {
      b <+ " selected"
    }
    b <+
      ">No approval required</option></select></label><label class=\"mr-checkbox\"><input type=\"checkbox\" name=\"allow_self_approval\""
    if rule.map(rule => rule.allow_self_approval).unwrap_or(false) {
      b <+ " checked"
    }
    b <+
      "><span>Allow authors to approve their own merge requests</span></label><p class=\"muted\">Author approval counts toward required approvals for this branch. Disabled by default.</p><label class=\"field\"><span>Required workflows (one path per line)</span><textarea name=\"checks\" aria-label=\"Required workflows (one path per line)\" rows=\"3\" maxlength=\"4096\" spellcheck=\"false\" placeholder=\".github/workflows/build.yml\">\{checks}</textarea><small>Read from the target branch; run against the merged source and target.</small></label><button type=\"submit\">\{if rule is Some(_) { "Save rule" } else { "Protect branch" }}</button></form>"
  })
}
