///|
fn layout(
  title : String,
  asset_path_map : Map[String, String],
  body : @moonback.Html,
  head_end? : @moonback.Html = @moonback.Html::raw(""),
  body_class? : String = "",
  current_user? : CurrentUser? = None,
) -> @moonback.Html {
  let stylesheet_head = app_styles_head(asset_path_map)
  let header = render_site_header(current_user)
  let main_class = if body_class.is_empty() {
    "page"
  } else {
    "page \{body_class}"
  }
  Html(b => {
    b <+
      $|<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\{stylesheet_head}<title>\{title}</title>\{head_end}</head><body>\{header}<main class="\{main_class}">\{body}</main></body></html>
  })
}

///|
fn render_site_header(current_user : CurrentUser?) -> @moonback.Html {
  Html(b => {
    b <+
      #|<header class="site-header"><div class="site-header__inner"><a class="brand" href="/">moonhub</a>
    match current_user {
      Some(user) =>
        b <+
          "<div class=\"site-header__actions\"><a class=\"header-link\" href=\"/teams\">Teams</a><span class=\"user-chip\">\{user.display_name}</span><form class=\"logout-form\" method=\"post\" action=\"/logout\"><button class=\"logout-button\" type=\"submit\">Sign out</button></form></div>"
      None => ()
    }
    b <+ "</div></header>"
  })
}

///|
fn repo_link(repo : RepoId) -> String {
  "/\{repo.path()}"
}

///|
fn render_index(
  repos~ : Array[RepoId],
  asset_path_map~ : Map[String, String],
  current_user? : CurrentUser? = None,
) -> @moonback.Html {
  layout(
    "moonhub",
    asset_path_map,
    Html(b => {
      b <+ "<div class=\"page-heading\"><h1>Repositories</h1></div>"
      if repos.is_empty() {
        b <+
          "<div class=\"empty-state\"><p class=\"muted\">No repositories available.</p></div>"
      } else {
        b <+
          "<div class=\"table-frame\"><div class=\"table-scroll\"><table><thead><tr><th>Repository</th></tr></thead><tbody>"
        for repo in repos {
          b <+
            "<tr><td><a class=\"repo-name\" href=\"\{repo_link(repo)}\">\{repo.path()}</a></td></tr>"
        }
        b <+ "</tbody></table></div></div>"
      }
    }),
    current_user~,
  )
}

///|
fn render_repo_nav(repo : RepoId, rev : String) -> @moonback.Html {
  Html(b => {
    let base = repo_link(repo)
    b <+
      "<div class=\"repo-header\"><h1 class=\"path repo-title\">\{repo.path()}</h1><p class=\"tabs\"><a href=\"\{base}\">Files</a><a href=\"\{base}/commits?rev=\{rev}\">Commits</a></p></div>"
  })
}

///|
async fn stream_commit_detail(
  b : @moonback.HtmlBuilder,
  git_dir : String,
  commit : String,
) -> Unit {
  let args = git_args(git_dir, [
    "show", "--diff-algorithm=histogram", "--patch", "--find-renames", "--date=iso-strict",
    commit,
  ])
  @async.with_task_group(group => {
    let (reader, writer) = @process.read_from_process()
    defer reader.close()
    let process = @process.spawn(
      group,
      "git",
      args,
      stdout=writer,
      stderr=writer,
    )
    let summary_text = match reader.read_until("\ndiff --git ") {
      Some(summary) => summary.trim().to_owned()
      None => ""
    }
    b <+ "<pre>\{summary_text}</pre>"
    if reader.read_some(max_len=8192) is Some(first_chunk) {
      let first_chunk = @moonback.Html::raw_utf8_chunk(first_chunk)
      b <+ "<moonhub-commit-diff><pre data-patch>diff --git \{first_chunk}"
      while reader.read_some(max_len=8192) is Some(chunk) {
        let chunk = @moonback.Html::raw_utf8_chunk(chunk)
        b <+ "\{chunk}"
      }
      b <+ "</pre></moonhub-commit-diff>"
    }
    let _ = process.wait()
  })
}

///|
async fn render_tree(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  rev~ : String,
  path~ : String,
  current_user? : CurrentUser? = None,
) -> @moonback.Html {
  let git_dir = repo.git_dir(root)
  let entries = list_tree(git_dir, rev, path) catch {
    GitCommandFailed(_) =>
      if path.is_empty() && is_unborn_default_ref(git_dir, rev) {
        []
      } else {
        raise NotFound(message="tree not found")
      }
    err => raise err
  }
  let base = "\{repo_link(repo)}/tree/\{url_escape_path(rev)}"
  layout(
    repo.path(),
    asset_path_map,
    Html(b => {
      b <+ "\{render_repo_nav(repo, rev)}"
      b <+
        "<div class=\"content-stack\"><h2 class=\"path\">/\{path}</h2><div class=\"table-frame\"><div class=\"table-scroll\"><table><thead><tr><th>Name</th><th>Type</th><th>Size</th></tr></thead><tbody>"
      if !path.is_empty() {
        b <+
          "<tr><td><a href=\"\{base}\">..</a></td><td class=\"muted\">parent</td><td></td></tr>"
      }
      for entry in entries {
        let child = if path.is_empty() {
          entry.name
        } else {
          "\{path}/\{entry.name}"
        }
        let child_url = url_escape_path(child)
        let href = if entry.kind == "tree" {
          "\{base}/\{child_url}"
        } else {
          "\{repo_link(repo)}/blob/\{url_escape_path(rev)}/\{child_url}"
        }
        let entry_size = entry.size.unwrap_or("")
        b <+
          "<tr><td><a class=\"path\" href=\"\{href}\">\{entry.name}</a></td><td>\{entry.kind}</td><td class=\"muted\">\{entry_size}</td></tr>"
      }
      if entries.is_empty() {
        b <+ "<tr><td colspan=\"3\" class=\"muted\">No files.</td></tr>"
      }
      b <+ "</tbody></table></div></div></div>"
    }),
    current_user~,
  )
}

///|
async fn render_blob(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  rev~ : String,
  path~ : String,
  current_user? : CurrentUser? = None,
) -> @moonback.Html {
  let content = read_blob(repo.git_dir(root), rev, path) catch {
    GitCommandFailed(_) => raise NotFound(message="file not found")
    err => raise err
  }
  layout(
    "\{repo.path()}:\{path}",
    asset_path_map,
    Html(b => {
      b <+ "\{render_repo_nav(repo, rev)}"
      b <+
        "<h2 class=\"path\">\{path}</h2><moonhub-file-view><span data-file-name hidden>\{path}</span><pre data-file-content>\{content}</pre></moonhub-file-view>"
    }),
    head_end=custom_elements_head(asset_path_map),
    current_user~,
  )
}

///|
async fn render_commits(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  rev~ : String,
  current_user? : CurrentUser? = None,
) -> @moonback.Html {
  let commits = list_commits(repo.git_dir(root), rev) catch {
    GitCommandFailed(_) =>
      if is_unborn_default_ref(repo.git_dir(root), rev) {
        []
      } else {
        raise NotFound(message="commit not found")
      }
    err => raise err
  }
  layout(
    "\{repo.path()} commits",
    asset_path_map,
    Html(b => {
      b <+ "\{render_repo_nav(repo, rev)}"
      b <+
        "<div class=\"content-stack\"><h2>Commits</h2><div class=\"table-frame\"><div class=\"table-scroll\"><table><thead><tr><th>Commit</th><th>Subject</th><th>Author</th><th>Date</th></tr></thead><tbody>"
      for commit in commits {
        let href = "\{repo_link(repo)}/commit/\{commit.hash}"
        let short_hash = commit.hash[:12].to_owned()
        b <+
          "<tr><td><a class=\"path\" href=\"\{href}\">\{short_hash}</a></td><td>\{commit.subject}</td><td>\{commit.author}</td><td class=\"muted\">\{commit.date}</td></tr>"
      }
      if commits.is_empty() {
        b <+ "<tr><td colspan=\"4\" class=\"muted\">No commits.</td></tr>"
      }
      b <+ "</tbody></table></div></div></div>"
    }),
    current_user~,
  )
}

///|
async fn render_commit(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  commit~ : String,
  current_user? : CurrentUser? = None,
) -> @moonback.Html {
  let git_dir = repo.git_dir(root)
  let _ = run_git(git_dir, ["cat-file", "-e", "\{commit}^{commit}"]) catch {
    GitCommandFailed(_) => raise NotFound(message="commit not found")
    err => raise err
  }
  layout(
    "\{repo.path()} \{commit}",
    asset_path_map,
    Html(b => {
      b <+ "\{render_repo_nav(repo, commit)}"
      b <+ "<h2 class=\"path\">\{commit}</h2>"
      stream_commit_detail(b, git_dir, commit)
    }),
    head_end=custom_elements_head(asset_path_map),
    current_user~,
  )
}

///|
fn render_login(
  asset_path_map : Map[String, String],
  message : String?,
) -> @moonback.Html {
  layout(
    "Sign in",
    asset_path_map,
    Html(b => {
      b <+ "<section class=\"auth-card\"><h1>Sign in</h1>"
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      b <+
        #|<form class="form-stack" method="post" action="/login">
        #|<label class="field"><span>Username</span><input name="name_key" autocomplete="username" required></label>
        #|<label class="field"><span>Password</span><input type="password" name="password" autocomplete="current-password" required></label>
        #|<p class="form-actions"><button type="submit">Sign in</button></p>
        #|</form></section>
    }),
    body_class="auth-main",
  )
}

///|
fn render_change_password(
  asset_path_map : Map[String, String],
  user : CurrentUser,
  message : String?,
  required : Bool,
) -> @moonback.Html {
  layout(
    "Change password",
    asset_path_map,
    Html(b => {
      b <+ "<section class=\"auth-card\"><h1>Change password</h1>"
      b <+
        "<p class=\"muted\">Signed in as \{user.display_name} (\{user.name_key}).</p>"
      if required {
        b <+ "<p class=\"muted\">You must set a password before continuing.</p>"
      }
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      b <+
        #|<form class="form-stack" method="post" action="/change-password">
        #|<label class="field"><span>New password</span><input type="password" name="new_password" autocomplete="new-password" minlength="8" required></label>
        #|<label class="field"><span>Confirm new password</span><input type="password" name="confirm_password" autocomplete="new-password" minlength="8" required></label>
        #|<p class="form-actions"><button type="submit">Change password</button></p>
        #|</form></section>
    }),
    body_class="auth-main",
    current_user=Some(user),
  )
}

///|
fn render_invitation_password(
  asset_path_map : Map[String, String],
  invitation : InvitationSession,
  message : String?,
) -> @moonback.Html {
  layout(
    "Set password",
    asset_path_map,
    Html(b => {
      b <+ "<section class=\"auth-card\"><h1>Set password</h1>"
      b <+
        "<p class=\"muted\">Signed in as \{invitation.display_name} (\{invitation.name_key}).</p>"
      b <+ "<p class=\"muted\">Set a password to activate this account.</p>"
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      b <+
        #|<form class="form-stack" method="post" action="/change-password">
        #|<label class="field"><span>New password</span><input type="password" name="new_password" autocomplete="new-password" minlength="8" required></label>
        #|<label class="field"><span>Confirm new password</span><input type="password" name="confirm_password" autocomplete="new-password" minlength="8" required></label>
        #|<p class="form-actions"><button type="submit">Set password</button></p>
        #|</form></section>
    }),
    body_class="auth-main",
  )
}

///|
fn render_teams(
  asset_path_map : Map[String, String],
  user : CurrentUser,
  teams : Array[TeamSummary],
  message : String?,
) -> @moonback.Html {
  layout(
    "Teams",
    asset_path_map,
    Html(b => {
      b <+
        #|<section class="page-heading page-heading--actions">
        #|<div><p class="eyebrow">Access</p><h1>Teams</h1><p class="page-subtitle">Manage repository namespaces and membership.</p></div>
      if user.is_site_admin {
        b <+ "<a class=\"button-link\" href=\"/teams/new\">New team</a>"
      }
      b <+ "</section>"
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      if teams.is_empty() {
        b <+
          "<section class=\"empty-state\"><p class=\"muted\">No teams available.</p></section>"
      } else {
        b <+
          "<section class=\"table-frame\"><div class=\"table-scroll\"><table><thead><tr><th>Team</th><th>Kind</th><th>Your role</th></tr></thead><tbody>"
        for team in teams {
          let role = team.role.unwrap_or(
            if user.is_site_admin {
              "site admin"
            } else {
              ""
            },
          )
          b <+
            "<tr><td><a class=\"repo-name path\" href=\"/teams/\{team.name_key}\">\{team.display_name}</a><div class=\"muted path\">\{team.name_key}</div></td><td>\{team.kind}</td><td>\{role}</td></tr>"
        }
        b <+ "</tbody></table></div></section>"
      }
    }),
    current_user=Some(user),
  )
}

///|
fn render_new_team(
  asset_path_map : Map[String, String],
  user : CurrentUser,
  message : String?,
) -> @moonback.Html {
  layout(
    "New team",
    asset_path_map,
    Html(b => {
      b <+
        #|<section class="page-heading">
        #|<p class="eyebrow">Admin</p>
        #|<h1>New team</h1>
        #|<p class="page-subtitle">Create an organization team. You will become its owner.</p>
        #|</section>
        #|<section class="panel"><form class="form-stack" method="post" action="/teams">
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      b <+
        #|<label class="field"><span>Name key</span><input name="name_key" autocomplete="off" required></label>
        #|<label class="field"><span>Display name</span><input name="display_name" required></label>
        #|<p class="form-actions"><button type="submit">Create team</button></p>
        #|</form></section>
    }),
    current_user=Some(user),
  )
}

///|
fn render_team_detail(
  asset_path_map : Map[String, String],
  user : CurrentUser,
  team : TeamSummary,
  members : Array[TeamMemberSummary],
  invitations : Array[InvitationSummary],
  can_manage~ : Bool,
  message : String?,
) -> @moonback.Html {
  layout(
    team.display_name,
    asset_path_map,
    Html(b => {
      b <+
        "<section class=\"page-heading\"><p class=\"eyebrow\">Team</p><h1>\{team.display_name}</h1><p class=\"page-subtitle path\">\{team.name_key}</p></section>"
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      b <+ "<div class=\"content-stack\">"
      b <+
        "<section><h2 class=\"section-title\">Members</h2><div class=\"table-frame\"><div class=\"table-scroll\"><table><thead><tr><th>User</th><th>Email</th><th>Role</th></tr></thead><tbody>"
      if members.is_empty() {
        b <+ "<tr><td colspan=\"3\" class=\"muted\">No members.</td></tr>"
      } else {
        for person in members {
          let email = person.email.unwrap_or("")
          b <+
            "<tr><td><span class=\"repo-name\">\{person.display_name}</span><div class=\"muted path\">\{person.name_key}</div></td><td>\{email}</td><td>\{person.role}</td></tr>"
        }
      }
      b <+ "</tbody></table></div></div></section>"
      if can_manage {
        b <+
          $|<section class="panel"><h2 class="section-title">Invite member</h2><form class="form-stack" method="post" action="/teams/\{team.name_key}/invitations">
          $|<label class="field"><span>Email</span><input type="email" name="email" autocomplete="email" required></label>
          $|<label class="field"><span>Name key</span><input name="name_key" autocomplete="off" required></label>
          $|<label class="field"><span>Display name</span><input name="display_name" required></label>
          $|<label class="field"><span>Role</span><select name="role"><option value="member">Member</option><option value="admin">Admin</option></select></label>
          $|<p class="form-actions"><button type="submit">Send invite</button></p>
          $|</form></section>
      }
      b <+
        "<section><h2 class=\"section-title\">Invitations</h2><div class=\"table-frame\"><div class=\"table-scroll\"><table><thead><tr><th>Email</th><th>User</th><th>Role</th><th>Status</th><th>Delivery</th><th></th></tr></thead><tbody>"
      if invitations.is_empty() {
        b <+ "<tr><td colspan=\"6\" class=\"muted\">No invitations.</td></tr>"
      } else {
        for invitation in invitations {
          let invitation_id = invitation.id.to_string()
          let role = invitation.role.unwrap_or("")
          let delivery_status = invitation.email_status.unwrap_or("not queued")
          b <+
            "<tr><td>\{invitation.email}</td><td><span class=\"repo-name\">\{invitation.display_name}</span><div class=\"muted path\">\{invitation.name_key}</div></td><td>\{role}</td><td>\{invitation.status}</td><td>\{delivery_status}"
          match invitation.email_sent_at {
            Some(sent_at) => b <+ "<div class=\"muted\">\{sent_at}</div>"
            None => ()
          }
          match invitation.email_last_error {
            Some(last_error) =>
              b <+ "<div class=\"flash-error\">\{last_error}</div>"
            None => ()
          }
          b <+ "</td><td>"
          if can_manage &&
            invitation.status == "sent" &&
            (
              invitation.email_status == Some("pending") ||
              invitation.email_status == Some("failed")
            ) &&
            invitation.email_last_error is Some(_) {
            b <+
              "<form class=\"inline-form\" method=\"post\" action=\"/teams/\{team.name_key}/invitations/\{invitation_id}/resend\"><button class=\"secondary-button\" type=\"submit\">Resend</button></form>"
          }
          if can_manage && invitation.status == "sent" {
            b <+
              "<form class=\"inline-form\" method=\"post\" action=\"/teams/\{team.name_key}/invitations/\{invitation_id}/revoke\"><button class=\"secondary-button\" type=\"submit\">Revoke</button></form>"
          }
          b <+ "</td></tr>"
        }
      }
      b <+ "</tbody></table></div></div></section></div>"
    }),
    current_user=Some(user),
  )
}

///|
fn render_error(
  status : Int,
  message : String,
  asset_path_map : Map[String, String],
  current_user? : CurrentUser? = None,
) -> @moonback.Html {
  let status_text = status.to_string()
  layout(
    "\{status} \{message}",
    asset_path_map,
    Html(b => {
      b <+
        "<section class=\"error-page\"><p class=\"error-code\">\{status_text}</p><h1 class=\"err\">\{message}</h1></section>"
    }),
    current_user~,
  )
}
