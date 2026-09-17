///|
fn layout(
  title : String,
  asset_path_map : Map[String, String],
  body : @moonback.Html,
  head_end? : @moonback.Html = @moonback.Html::raw(""),
  body_class? : String = "",
  current_user? : CurrentUser? = None,
  navigation? : PageNavigation = WorkspaceNavigation("repositories"),
) -> @moonback.Html {
  let stylesheet_head = app_styles_head(asset_path_map)
  let shell_script = vite_manifest_entry_path(
    asset_path_map, "src/app-shell.ts",
  )
  let shell = current_user is Some(_) ||
    navigation is RepositoryNavigation(_, _, _)
  let header = render_site_header(current_user, navigation, shell)
  let main_class = if body_class.is_empty() {
    "page"
  } else {
    "page \{body_class}"
  }
  Html(b => {
    b <+
      $|<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">\{stylesheet_head}<title>\{title} · moonhub</title><script id="sidebar-preference">if(\{shell.to_string()})document.documentElement.dataset.uiEnhanced='true';try{if(\{shell.to_string()}&&localStorage.getItem('moonhub.sidebar')==='collapsed')document.documentElement.dataset.sidebarCollapsed='true'}catch{}</script><script type="module" src="\{shell_script}" onerror="document.documentElement.removeAttribute('data-ui-enhanced');document.documentElement.removeAttribute('data-sidebar-collapsed')"></script>\{head_end}</head><body><a class="skip-link" href="#main-content">Skip to content</a>\{header}
    if shell {
      b <+
        "<div class=\"workspace-shell\">\{render_sidebar(navigation, current_user)}"
    }
    b <+
      "<main id=\"main-content\" class=\"\{main_class}\" tabindex=\"-1\">\{body}</main>"
    if shell {
      b <+ "</div>"
    }
    b <+ "</body></html>"
  })
}

///|
fn render_site_header(
  current_user : CurrentUser?,
  navigation : PageNavigation,
  shell : Bool,
) -> @moonback.Html {
  Html(b => {
    b <+
      #|<header class="site-header"><div class="site-header__inner"><div class="brand-area">
    if shell {
      b <+
        "<button class=\"icon-button mobile-menu-button\" type=\"button\" data-sidebar-open aria-label=\"Open navigation\" title=\"Open navigation\" aria-controls=\"app-sidebar\" aria-expanded=\"false\" hidden inert><span class=\"ui-icon\" data-icon=\"menu\" aria-hidden=\"true\"></span></button>"
    }
    b <+
      "<a class=\"brand\" href=\"/\" aria-label=\"moonhub home\"><span class=\"brand-mark\"><span class=\"ui-icon\" data-icon=\"moon\" aria-hidden=\"true\"></span></span><span class=\"brand-label\">moonhub</span></a></div>"
    if shell {
      b <+ "\{render_breadcrumbs(navigation)}"
    }
    match current_user {
      Some(user) => {
        b <+
          "<details class=\"account-menu\" data-dismissable><summary aria-label=\"Account menu\" title=\"Account menu\"><span class=\"avatar\" aria-hidden=\"true\">\{user.name_key[:1].to_owned().to_upper()}</span><span class=\"account-name\">\{user.display_name}</span><span class=\"ui-icon\" data-icon=\"chevron-down\" aria-hidden=\"true\"></span></summary><div class=\"account-menu-panel\"><div class=\"account-identity\"><strong>\{user.display_name}</strong><span>\{user.name_key}</span></div><a href=\"/settings/profile\"><span class=\"ui-icon\" data-icon=\"user\" aria-hidden=\"true\"></span>Profile</a><a href=\"/settings/ssh-keys\"><span class=\"ui-icon\" data-icon=\"key\" aria-hidden=\"true\"></span>SSH keys</a><a href=\"/change-password\"><span class=\"ui-icon\" data-icon=\"lock\" aria-hidden=\"true\"></span>Change password</a>"
        if user.is_site_admin {
          b <+
            "<a href=\"/admin/settings/ssh\" aria-label=\"Site settings\"><span class=\"ui-icon\" data-icon=\"settings\" aria-hidden=\"true\"></span>Site settings</a>"
        }
        b <+
          "<form class=\"logout-form\" method=\"post\" action=\"/logout\"><button class=\"logout-button\" type=\"submit\"><span class=\"ui-icon\" data-icon=\"log-out\" aria-hidden=\"true\"></span>Sign out</button></form></div></details>"
      }
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
  personal_owner? : String? = None,
) -> @moonback.Html {
  layout(
    "moonhub",
    asset_path_map,
    Html(b => {
      b <+
        "<div class=\"page-heading page-heading--actions\"><div class=\"heading-title\"><h1>Repositories</h1><span class=\"count-badge\">\{repos.length().to_string()}</span></div>"
      if personal_owner is Some(owner) {
        b <+
          "<a class=\"button-link\" href=\"/teams/\{owner}/repositories/new\"><span class=\"ui-icon\" data-icon=\"plus\" aria-hidden=\"true\"></span>New repository</a>"
      }
      b <+
        "<a class=\"secondary-button button-link\" href=\"/teams\"><span class=\"ui-icon\" data-icon=\"users\" aria-hidden=\"true\"></span>Browse teams</a></div>"
      if repos.is_empty() {
        b <+
          "<div class=\"empty-state\"><span class=\"empty-icon ui-icon\" data-icon=\"book-open\" aria-hidden=\"true\"></span><h2>No repositories yet</h2>"
        if personal_owner is Some(owner) {
          b <+
            "<a href=\"/teams/\{owner}/repositories/new\">Create your first repository</a>"
        }
        b <+ "<a href=\"/teams\">Browse your teams</a></div>"
      } else {
        b <+
          "<section data-filter-list><div class=\"list-toolbar\"><label class=\"search-field\" hidden inert data-filter-control><span class=\"ui-icon\" data-icon=\"search\" aria-hidden=\"true\"></span><input type=\"search\" data-list-filter placeholder=\"Find a repository...\" aria-label=\"Find a repository\"></label><span class=\"list-total\" data-list-total>\{repos.length().to_string()} repositories</span></div><ul class=\"repository-list\">"
        for repo in repos {
          b <+
            "<li data-filter-item data-filter-text=\"\{repo.path()}\"><a class=\"repository-list-link\" href=\"\{repo_link(repo)}\"><span class=\"repository-icon\"><span class=\"ui-icon\" data-icon=\"book-open\" aria-hidden=\"true\"></span></span><span class=\"repository-identity\"><strong>\{repo.name}</strong><span>\{repo.path()}</span></span><span class=\"repository-owner\">\{repo.owner}</span><span class=\"ui-icon row-chevron\" data-icon=\"chevron-right\" aria-hidden=\"true\"></span></a></li>"
        }
        b <+
          "</ul><p class=\"filter-empty empty-state\" data-filter-empty hidden>No matching repositories.</p></section>"
      }
    }),
    current_user~,
  )
}

///|
fn render_repo_nav(
  repo : RepoId,
  rev : String,
  clone_url : String?,
) -> @moonback.Html {
  Html(b => {
    let base = repo_link(repo)
    b <+
      "<div class=\"repo-header\"><div class=\"repo-heading\"><div class=\"repo-title-group\"><span class=\"repository-icon\"><span class=\"ui-icon\" data-icon=\"book-open\" aria-hidden=\"true\"></span></span><h1 class=\"repo-title\">\{repo.name}</h1></div><details class=\"repo-clone\" data-dismissable><summary><span class=\"ui-icon\" data-icon=\"code\" aria-hidden=\"true\"></span>Clone<span class=\"ui-icon\" data-icon=\"chevron-down\" data-clone-icon=\"chevron\" aria-hidden=\"true\"></span></summary><div class=\"repo-clone-panel\">"
    match clone_url {
      Some(url) =>
        b <+
          "<label class=\"repo-clone-label\" for=\"repo-clone-url\">Clone with SSH</label><div class=\"repo-clone-field\"><input id=\"repo-clone-url\" class=\"path\" data-clone-url value=\"\{url}\" readonly spellcheck=\"false\"><button type=\"button\" class=\"repo-copy-button\" data-clone-copy title=\"Copy SSH URL\" aria-label=\"Copy SSH URL\" disabled><span class=\"ui-icon\" data-icon=\"copy\" data-clone-icon=\"copy\" aria-hidden=\"true\"></span></button></div><p class=\"repo-clone-status\" data-clone-status role=\"status\" aria-live=\"polite\"></p>"
      None => b <+ "<p class=\"muted\">SSH clone address is not configured.</p>"
    }
    b <+
      "</div></details></div><div class=\"repo-context-line\"><a href=\"\{base}\">\{repo.path()}</a><span class=\"branch-label\"><span class=\"ui-icon\" data-icon=\"git-branch\" aria-hidden=\"true\"></span>\{rev}</span></div></div>"
  })
}

///|
fn escape_html_text_chunk(chunk : Bytes) -> Bytes {
  // Escape markup bytes without decoding UTF-8 split across stream chunks.
  let escaped : Array[Byte] = []
  for byte in chunk {
    match byte {
      b'&' => escaped.append(b"&amp;".to_array())
      b'<' => escaped.append(b"&lt;".to_array())
      b'>' => escaped.append(b"&gt;".to_array())
      _ => escaped.push(byte)
    }
  }
  Bytes::from_array(escaped)
}

///|
async fn stream_commit_detail(
  b : @moonback.HtmlBuilder,
  git_dir : String,
  commit : String,
) -> Unit {
  let args = git_args(git_dir, [
    "show", "--no-color", "--no-ext-diff", "--no-textconv", "--format=medium", "--diff-algorithm=histogram",
    "--diff-merges=first-parent", "--patch", "--find-renames", "--src-prefix=a/",
    "--dst-prefix=b/", "--date=iso-strict", commit, "--",
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
    b <+ "<pre>\{summary_text}</pre><h2>Changes</h2>"
    if reader.read_some(max_len=8192) is Some(first_chunk) {
      let first_chunk = @moonback.Html::raw_utf8_chunk(
        escape_html_text_chunk(first_chunk),
      )
      b <+ "<moonhub-commit-diff><pre data-patch>diff --git \{first_chunk}"
      while reader.read_some(max_len=8192) is Some(chunk) {
        let chunk = @moonback.Html::raw_utf8_chunk(
          escape_html_text_chunk(chunk),
        )
        b <+ "\{chunk}"
      }
      b <+ "</pre></moonhub-commit-diff>"
    } else {
      b <+ "<p class=\"muted\">No file changes.</p>"
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
  clone_url? : String? = None,
  current_user? : CurrentUser? = None,
  manager? : Bool = false,
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
      b <+ "\{render_repo_nav(repo, rev, clone_url)}"
      b <+
        "<div class=\"content-stack\"><h2 class=\"file-path-heading\{if path.is_empty() { "" } else { " path" }}\">\{if path.is_empty() { "Files" } else { path }}</h2><div class=\"table-frame file-table\"><div class=\"table-scroll\"><table><thead><tr><th>Name</th><th class=\"numeric\" title=\"Bytes\">Size</th></tr></thead><tbody>"
      if !path.is_empty() {
        b <+
          "<tr><td><a href=\"\{base}\" aria-label=\"Parent directory\">..</a></td><td></td></tr>"
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
        let entry_size = entry.size.unwrap_or("-")
        b <+
          "<tr><td><a class=\"file-link\" href=\"\{href}\"><span class=\"ui-icon\" data-icon=\"\{if entry.kind == "tree" { "folder" } else { "file" }}\" aria-hidden=\"true\"></span>\{entry.name}</a></td><td class=\"muted numeric\">\{entry_size}</td></tr>"
      }
      if entries.is_empty() {
        b <+ "<tr><td colspan=\"2\" class=\"muted\">No files.</td></tr>"
      }
      b <+ "</tbody></table></div></div></div>"
    }),
    head_end=repository_assets_head(asset_path_map),
    current_user~,
    navigation=RepositoryNavigation(repo, "files", manager),
  )
}

///|
async fn render_blob(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  rev~ : String,
  path~ : String,
  clone_url? : String? = None,
  current_user? : CurrentUser? = None,
  manager? : Bool = false,
) -> @moonback.Html {
  let content = read_blob(repo.git_dir(root), rev, path) catch {
    GitCommandFailed(_) => raise NotFound(message="file not found")
    err => raise err
  }
  layout(
    "\{repo.path()}:\{path}",
    asset_path_map,
    Html(b => {
      b <+ "\{render_repo_nav(repo, rev, clone_url)}"
      b <+
        "<h2 class=\"path\">\{path}</h2><moonhub-file-view><span data-file-name hidden>\{path}</span><pre data-file-content>\{content}</pre></moonhub-file-view>"
    }),
    head_end=repository_assets_head(asset_path_map, code_view=true),
    current_user~,
    navigation=RepositoryNavigation(repo, "files", manager),
  )
}

///|
async fn render_commits(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  rev~ : String,
  clone_url? : String? = None,
  current_user? : CurrentUser? = None,
  manager? : Bool = false,
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
      b <+ "\{render_repo_nav(repo, rev, clone_url)}"
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
    head_end=repository_assets_head(asset_path_map),
    current_user~,
    navigation=RepositoryNavigation(repo, "commits", manager),
  )
}

///|
async fn render_commit(
  root~ : String,
  asset_path_map~ : Map[String, String],
  repo~ : RepoId,
  commit~ : String,
  clone_url? : String? = None,
  current_user? : CurrentUser? = None,
  manager? : Bool = false,
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
      b <+ "\{render_repo_nav(repo, commit, clone_url)}"
      b <+ "<h2 class=\"path\">\{commit}</h2>"
      stream_commit_detail(b, git_dir, commit)
    }),
    head_end=repository_assets_head(asset_path_map, code_view=true),
    current_user~,
    navigation=RepositoryNavigation(repo, "commits", manager),
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
    navigation=AccountNavigation("password"),
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
        #|<div class="heading-title"><h1>Teams</h1></div>
      if user.is_site_admin {
        b <+
          "<a class=\"button-link\" href=\"/teams/new\"><span class=\"ui-icon\" data-icon=\"plus\" aria-hidden=\"true\"></span>New team</a>"
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
          "<section class=\"table-frame\"><div class=\"table-scroll\"><table class=\"teams-table\"><thead><tr><th>Team</th><th>Type</th><th>Your role</th></tr></thead><tbody>"
        for team in teams {
          let role = team.role.unwrap_or(
            if user.is_site_admin {
              "site admin"
            } else {
              ""
            },
          )
          b <+
            "<tr><td><div class=\"identity-cell\"><span class=\"team-avatar\" aria-hidden=\"true\">\{team.name_key[:1].to_owned().to_upper()}</span><span><a class=\"repo-name\" href=\"/teams/\{team.name_key}\">\{team.display_name}</a><span class=\"cell-secondary\">\{team.name_key}</span></span></div></td><td class=\"muted\">\{if team.kind == "org" { "Organization" } else { "Personal" }}</td><td><span class=\"role-label\">\{role}</span></td></tr>"
        }
        b <+ "</tbody></table></div></section>"
      }
    }),
    current_user=Some(user),
    navigation=WorkspaceNavigation("teams"),
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
        #|<h1>New team</h1>
        #|</section>
        #|<section class="panel"><form class="form-stack" method="post" action="/teams">
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      b <+
        #|<label class="field"><span>Team handle</span><input name="name_key" autocomplete="off" required></label>
        #|<label class="field"><span>Display name</span><input name="display_name" required></label>
        #|<p class="form-actions"><button type="submit">Create team</button></p>
        #|</form></section>
    }),
    current_user=Some(user),
    navigation=WorkspaceNavigation("teams"),
    body_class="form-page",
  )
}

///|
fn render_team_detail(
  asset_path_map : Map[String, String],
  user : CurrentUser,
  team : TeamSummary,
  members : Array[TeamMemberSummary],
  invitations : Array[InvitationSummary],
  repositories~ : Array[TeamRepository],
  can_manage~ : Bool,
  invitation_credentials_csrf~ : String,
  message : String?,
  active_tab? : String = "repositories",
  invite_open? : Bool = false,
  invitation_form? : Map[String, String] = Map([]),
  notice? : String? = None,
) -> @moonback.Html {
  layout(
    team.display_name,
    asset_path_map,
    Html(b => {
      b <+
        "<section class=\"page-heading team-heading\"><span class=\"team-avatar team-avatar-large\" aria-hidden=\"true\">\{team.name_key[:1].to_owned().to_upper()}</span><div><h1>\{team.display_name}</h1><p class=\"page-subtitle\">\{team.name_key}<span class=\"metadata-separator\" aria-hidden=\"true\">/</span>\{repositories.length().to_string()} repositories<span class=\"metadata-separator\" aria-hidden=\"true\">/</span>\{members.length().to_string()} members</p></div></section>"
      if notice is Some(notice) {
        b <+
          "<p class=\"settings-success\" role=\"status\"><span class=\"ui-icon\" data-icon=\"circle-check\" aria-hidden=\"true\"></span>\{notice}</p>"
      }
      b <+ "<div id=\"team-repositories\""
      if active_tab != "repositories" {
        b <+ " hidden"
      }
      b <+
        ">\{render_team_repositories(team, repositories, can_manage)}</div><section id=\"team-members\""
      if active_tab != "members" {
        b <+ " hidden"
      }
      b <+ "><div class=\"section-heading\"><h2>Members</h2>"
      if can_manage {
        b <+
          "<a class=\"button-link\" href=\"/teams/\{team.name_key}?tab=invitations&amp;invite=1\"><span class=\"ui-icon\" data-icon=\"user-plus\" aria-hidden=\"true\"></span>Invite member</a>"
      }
      b <+
        "</div><div class=\"table-frame\"><div class=\"table-scroll\"><table class=\"members-table\"><thead><tr><th>Member</th><th>Email</th><th>Role</th></tr></thead><tbody>"
      if members.is_empty() {
        b <+ "<tr><td colspan=\"3\" class=\"muted\">No members.</td></tr>"
      } else {
        for person in members {
          let email = person.email.unwrap_or("")
          b <+
            "<tr><td><div class=\"identity-cell\"><span class=\"avatar\" aria-hidden=\"true\">\{person.name_key[:1].to_owned().to_upper()}</span><span><strong>\{person.display_name}</strong><span class=\"cell-secondary\">\{person.name_key}</span></span></div></td><td class=\"muted\">\{email}</td><td><span class=\"role-label\">\{person.role}</span></td></tr>"
        }
      }
      b <+
        "</tbody></table></div></div></section><section id=\"team-invitations\""
      if active_tab != "invitations" {
        b <+ " hidden"
      }
      b <+ "><div class=\"section-heading\"><h2>Invitations</h2>"
      if can_manage && !invite_open {
        b <+
          "<a class=\"button-link\" href=\"/teams/\{team.name_key}?tab=invitations&amp;invite=1\"><span class=\"ui-icon\" data-icon=\"user-plus\" aria-hidden=\"true\"></span>Invite member</a>"
      }
      b <+ "</div>"
      if can_manage {
        b <+
          "<form class=\"invite-form\" method=\"post\" action=\"/teams/\{team.name_key}/invitations\""
        if !invite_open {
          b <+ " hidden"
        }
        b <+ "><h3>Invite member</h3>"
        if message is Some(message) {
          b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
        }
        b <+
          "<div class=\"invite-fields\"><label class=\"field\"><span>Email</span><input type=\"email\" name=\"email\" autocomplete=\"email\" value=\"\{invitation_form.get("email").unwrap_or("")}\" required></label><label class=\"field\"><span>Username</span><input name=\"name_key\" autocomplete=\"off\" value=\"\{invitation_form.get("name_key").unwrap_or("")}\" required></label><label class=\"field\"><span>Display name</span><input name=\"display_name\" autocomplete=\"name\" value=\"\{invitation_form.get("display_name").unwrap_or("")}\" required></label><label class=\"field\"><span>Role</span><select name=\"role\" aria-label=\"Role\"><option value=\"member\">Member</option><option value=\"admin\""
        if invitation_form.get("role") == Some("admin") {
          b <+ " selected"
        }
        b <+
          ">Admin</option></select></label></div><div class=\"form-actions\"><button type=\"submit\"><span class=\"ui-icon\" data-icon=\"send\" aria-hidden=\"true\"></span>Send invite</button><a class=\"secondary-button button-link\" href=\"/teams/\{team.name_key}?tab=invitations\">Cancel</a></div></form>"
      }
      b <+
        "<div class=\"table-frame\"><div class=\"table-scroll\"><table class=\"invitations-table\"><thead><tr><th>Email</th><th>User</th><th>Role</th><th>Status</th><th>Delivery</th><th><span class=\"sr-only\">Actions</span></th></tr></thead><tbody>"
      if invitations.is_empty() {
        b <+ "<tr><td colspan=\"6\" class=\"muted\">No invitations.</td></tr>"
      } else {
        for invitation in invitations {
          let invitation_id = invitation.id.to_string()
          let role = invitation.role.unwrap_or("")
          let delivery_status = invitation.email_status.unwrap_or("not queued")
          let status_label = match invitation.status {
            "sent" => "Awaiting acceptance"
            "accepted" => "Accepted"
            "expired" => "Expired"
            _ => "Revoked"
          }
          let delivery_label = match delivery_status {
            "pending" => "Queued"
            "sent" => "Delivered"
            "failed" => "Failed"
            _ => "Not queued"
          }
          b <+
            "<tr><td>\{invitation.email}</td><td><span class=\"repo-name\">\{invitation.display_name}</span><div class=\"cell-secondary\">\{invitation.name_key}</div></td><td><span class=\"role-label\">\{role}</span></td><td><span class=\"status-badge\" data-status=\"\{invitation.status}\">\{status_label}</span></td><td><span class=\"delivery-state\" data-delivery=\"\{delivery_status}\">\{delivery_label}</span>"
          match invitation.email_sent_at {
            Some(sent_at) => b <+ "<div class=\"muted\">\{sent_at}</div>"
            None => ()
          }
          match invitation.email_last_error {
            Some(_) =>
              b <+
                "<details class=\"delivery-detail\"><summary>Details</summary><p class=\"flash-error\">\{email_delivery_error_message}</p></details>"
            None => ()
          }
          b <+ "</td><td><div class=\"row-action-group\">"
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
          if (can_manage || user.is_site_admin) && invitation.status == "sent" {
            b <+
              "<details class=\"row-menu\" data-dismissable><summary class=\"icon-button\" aria-label=\"Invitation actions for \{invitation.email}\" title=\"More actions\"><span class=\"ui-icon\" data-icon=\"ellipsis\" aria-hidden=\"true\"></span></summary><div class=\"row-menu-panel\">"
            if user.is_site_admin && invitation.email_status is Some(_) {
              b <+
                "<form class=\"inline-form\" method=\"post\" action=\"/teams/\{team.name_key}/invitations/\{invitation_id}/credentials\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{invitation_credentials_csrf}\"><button class=\"secondary-button\" type=\"submit\">View sign-in details</button></form>"
            }
            if can_manage {
              b <+
                "<form class=\"inline-form\" method=\"post\" action=\"/teams/\{team.name_key}/invitations/\{invitation_id}/revoke\"><button class=\"danger-button secondary-button\" type=\"submit\">Revoke</button></form>"
            }
            b <+ "</div></details>"
          }
          b <+ "</div></td></tr>"
        }
      }
      b <+ "</tbody></table></div></div></section>"
    }),
    current_user=Some(user),
    navigation=TeamNavigation(team, active_tab),
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
        "<section class=\"error-page\"><p class=\"error-code\">\{status_text}</p><h1 class=\"err\">\{message}</h1><p><a class=\"button-link secondary-button\" href=\"/\">Back to repositories</a></p></section>"
    }),
    current_user~,
  )
}
