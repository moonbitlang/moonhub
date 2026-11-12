///|
pub(all) enum PageNavigation {
  WorkspaceNavigation(String)
  TeamNavigation(@identity.TeamSummary, String)
  PersonalNavigation(@identity.TeamSummary)
  RepositoryNavigation(@domain.RepoId, String, Bool)
  AccountNavigation(String)
  SiteNavigation(String)
}

///|
/// A user's own namespace is not a team in the product, so it never uses the
/// team views, labels, or sections.
pub fn namespace_navigation(
  team : @identity.TeamSummary,
  active : String,
) -> PageNavigation {
  if team.kind == "personal" {
    PersonalNavigation(team)
  } else {
    TeamNavigation(team, active)
  }
}

///|
/// Accessible name for a link that leaves a page back to its namespace.
pub fn namespace_back_label(team : @identity.TeamSummary) -> String {
  if team.kind == "personal" {
    "Repositories"
  } else {
    "Team"
  }
}

///|
fn render_navigation_item(
  href : String,
  label : String,
  icon : String,
  active : Bool,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<a class=\"nav-item\" href=\"\{href}\" aria-label=\"\{label}\" title=\"\{label}\""
    if active {
      b <+ " aria-current=\"page\""
    }
    b <+
      "><span class=\"ui-icon\" data-icon=\"\{icon}\" aria-hidden=\"true\"></span><span class=\"nav-label\">\{label}</span></a>"
  })
}

///|
pub fn render_breadcrumb_trail(
  items : Array[(String, String?)],
  label~ : String = "Breadcrumb",
  file_path~ : Bool = false,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<nav class=\"breadcrumbs\{if file_path { " file-breadcrumbs" } else { "" }}\" aria-label=\"\{label}\"><ol>"
    for i, (text, href) in items {
      let current = i == items.length() - 1
      b <+ "<li>"
      if i > 0 {
        b <+
          "<span class=\"ui-icon breadcrumb-separator\" data-icon=\"chevron-right\" aria-hidden=\"true\"></span>"
      }
      if current && file_path {
        b <+ "<h2 aria-current=\"page\">"
      }
      match href {
        Some(href) => {
          b <+ "<a href=\"\{href}\" title=\"\{text}\""
          if current {
            b <+ " aria-current=\"page\""
          }
          b <+ ">"
        }
        None => b <+ "<span class=\"breadcrumb-label\">"
      }
      if file_path && i == 0 {
        b <+
          "<span class=\"ui-icon\" data-icon=\"folders\" aria-hidden=\"true\"></span>"
      }
      b <+ "\{text}"
      match href {
        Some(_) => b <+ "</a>"
        None => b <+ "</span>"
      }
      if current && file_path {
        b <+ "</h2>"
      }
      b <+ "</li>"
    }
    b <+ "</ol></nav>"
  })
}

///|
fn render_breadcrumbs(navigation : PageNavigation) -> @moonback.Html {
  let items : Array[(String, String?)] = match navigation {
    WorkspaceNavigation(section) => {
      let (label, href) = match section {
        "teams" => ("Teams", "/-/teams")
        "notifications" => ("Inbox", "/-/notifications")
        _ => ("Repositories", "/")
      }
      [("Workspace", Some("/")), (label, Some(href))]
    }
    TeamNavigation(team, active) => {
      let label = match active {
        "members" => "Members"
        "invitations" => "Invitations"
        _ => "Repositories"
      }
      [
        ("Teams", Some("/-/teams")),
        (team.display_name, Some("/\{team.name_key}")),
        (label, Some("/\{team.name_key}?tab=\{active}")),
      ]
    }
    PersonalNavigation(team) =>
      [("Workspace", Some("/")), (team.display_name, Some("/\{team.name_key}"))]
    RepositoryNavigation(repo, active, _) => {
      let base = repo_link(repo)
      let (label, suffix) = match active {
        "commits" => ("Commits", "/commits")
        "issues" => ("Issues", "/issues")
        "merge-requests" => ("Merge requests", "/merge-requests")
        "pipelines" => ("Pipelines", "/pipelines")
        "releases" => ("Releases", "/releases")
        "webhooks" => ("Webhooks", "/settings/webhooks")
        "settings" => ("Branch protection", "/settings/branches")
        "deploy-keys" => ("Deploy keys", "/settings/deploy-keys")
        "secrets" => ("Repository secrets", "/settings/secrets")
        "variables" => ("Repository variables", "/settings/variables")
        _ => ("Files", "")
      }
      [
        (repo.owner, Some("/\{repo.owner}")),
        (repo.name, Some(base)),
        (label, Some(base + suffix)),
      ]
    }
    AccountNavigation(active) => {
      let (label, href) = match active {
        "ssh-keys" => ("SSH keys", "/-/settings/ssh-keys")
        "password" => ("Password", "/-/change-password")
        "tokens" => ("Access tokens", "/-/settings/tokens")
        _ => ("Profile", "/-/settings/profile")
      }
      [
        ("Account", Some("/-/settings/profile")),
        ("Settings", Some("/-/settings/profile")),
        (label, Some(href)),
      ]
    }
    SiteNavigation(active) => {
      let (label, href) = match active {
        "mail" => ("Email delivery", "/-/admin/settings/mail")
        "pipeline-providers" =>
          ("Pipeline providers", "/-/admin/pipelines/providers")
        _ => ("SSH access", "/-/admin/settings/ssh")
      }
      [
        ("Administration", Some("/-/admin/settings/ssh")),
        ("Site settings", Some("/-/admin/settings/ssh")),
        (label, Some(href)),
      ]
    }
  }
  render_breadcrumb_trail(items)
}

///|
fn render_sidebar(
  navigation : PageNavigation,
  current_user : @domain.CurrentUser?,
) -> @moonback.Html {
  let (name, subtitle, icon) = match navigation {
    TeamNavigation(team, _) => (team.display_name, "Team workspace", "users")
    PersonalNavigation(team) =>
      (team.display_name, "Personal repositories", "user")
    RepositoryNavigation(repo, _, _) => (repo.name, repo.owner, "book-open")
    AccountNavigation(_) => ("Your account", "Personal settings", "user")
    SiteNavigation(_) => ("Administration", "Site settings", "settings")
    _ => ("Workspace", "Your repositories & teams", "grid")
  }
  Html(b => {
    b <+
      "<aside id=\"app-sidebar\" class=\"sidebar\" aria-label=\"Workspace navigation\"><div class=\"sidebar-mobile-heading\"><strong>Navigation</strong><button type=\"button\" class=\"icon-button\" data-sidebar-close aria-label=\"Close navigation\" title=\"Close navigation\"><span class=\"ui-icon\" data-icon=\"x\" aria-hidden=\"true\"></span></button></div><details class=\"context-switcher\" data-dismissable><summary aria-label=\"Switch workspace\" title=\"Switch workspace\"><span class=\"context-icon\"><span class=\"ui-icon\" data-icon=\"\{icon}\" aria-hidden=\"true\"></span></span><span class=\"context-text\"><strong>\{name}</strong><span>\{subtitle}</span></span><span class=\"ui-icon context-chevron\" data-icon=\"chevrons-up-down\" aria-hidden=\"true\"></span></summary><div class=\"context-menu\"><a href=\"/\">All repositories</a><a href=\"/-/teams\">All teams</a>"
    match navigation {
      RepositoryNavigation(repo, _, _) =>
        b <+ "<a href=\"/\{repo.owner}\">\{repo.owner} workspace</a>"
      _ => ()
    }
    b <+ "</div></details><div class=\"sidebar-scroll\">"
    if !(navigation is RepositoryNavigation(_, _, _) ||
      navigation is TeamNavigation(_, _)) {
      b <+ "<nav class=\"nav-group\" aria-label=\"Workspace\">"
      b <+
        "\{render_navigation_item("/", "Repositories", "folders", navigation is WorkspaceNavigation("repositories"))}\{render_navigation_item("/-/teams", "Teams", "users", navigation is WorkspaceNavigation("teams"))}"
      if current_user is Some(_) {
        b <+
          "\{render_navigation_item("/-/notifications", "Inbox", "mail", navigation is WorkspaceNavigation("notifications"))}"
      }
      b <+ "</nav>"
    }
    match navigation {
      TeamNavigation(team, active) => {
        b <+
          "<nav class=\"nav-group\" aria-label=\"Team\"><p class=\"nav-group-label\">\{team.display_name}</p>"
        let base = "/\{team.name_key}"
        for
          (key, label, icon) in [
            ("repositories", "Team repositories", "book-open"),
            ("members", "Members", "contact"),
            ("invitations", "Invitations", "mail"),
          ] {
          b <+
            "\{render_navigation_item("\{base}?tab=\{key}", label, icon, active == key)}"
        }
        b <+ "</nav>"
      }
      RepositoryNavigation(repo, active, manager) => {
        b <+
          "<nav class=\"nav-group\" aria-label=\"Repository\"><p class=\"nav-group-label\">Repository</p>"
        let base = repo_link(repo)
        for
          (suffix, key, label, icon) in [
            ("", "files", "Files", "code"),
            ("/commits", "commits", "Commits", "git-commit"),
            ("/issues", "issues", "Issues", "circle-dot"),
            (
              "/merge-requests", "merge-requests", "Merge requests", "git-pull-request",
            ),
            ("/pipelines", "pipelines", "Pipelines", "git-commit"),
            ("/releases", "releases", "Releases", "tag"),
            ("/settings/variables", "variables", "Variables", "settings"),
          ] {
          b <+
            "\{render_navigation_item(base + suffix, label, icon, active == key)}"
        }
        if manager {
          b <+
            "\{render_navigation_item(base + "/settings/secrets", "Secrets", "key", active == "secrets")}"
          b <+
            "\{render_navigation_item(base + "/settings/mirrors", "Mirrors", "git-commit", active == "mirrors")}"
          b <+
            "\{render_navigation_item(base + "/settings/webhooks", "Webhooks", "settings", active == "webhooks")}"
          b <+
            "\{render_navigation_item(base + "/settings/branches", "Branch protection", "settings", active == "settings")}"
          b <+
            "\{render_navigation_item(base + "/settings/deploy-keys", "Deploy keys", "key", active == "deploy-keys")}"
        }
        b <+ "</nav>"
      }
      AccountNavigation(active) =>
        b <+
          "<nav class=\"nav-group context-navigation\" aria-label=\"Account settings\"><p class=\"nav-group-label\">Account</p>\{render_navigation_item("/-/settings/profile", "Profile", "user", active == "profile")}\{render_navigation_item("/-/settings/ssh-keys", "SSH keys", "key", active == "ssh-keys")}\{render_navigation_item("/-/change-password", "Password", "lock", active == "password")}\{render_navigation_item("/-/settings/tokens", "Access tokens", "key", active == "tokens")}</nav>"
      SiteNavigation(active) =>
        b <+
          "<nav class=\"nav-group context-navigation\" aria-label=\"Site settings\"><p class=\"nav-group-label\">Administration</p>\{render_navigation_item("/-/admin/settings/ssh", "SSH access", "terminal", active == "ssh")}\{render_navigation_item("/-/admin/settings/mail", "Email delivery", "mail", active == "mail")}\{render_navigation_item("/-/admin/pipelines/providers", "Pipeline providers", "git-commit", active == "pipeline-providers")}</nav>"
      _ => ()
    }
    // Site settings are administration, not part of any workspace scope, so the
    // entry is offered from every page instead of only inside the account menu.
    let site_admin = match current_user {
      Some(user) => user.is_site_admin
      None => false
    }
    if site_admin {
      // The site settings scope already lists its own sections.
      match navigation {
        SiteNavigation(_) => ()
        _ =>
          b <+
            "<nav class=\"nav-group context-navigation\" aria-label=\"Site settings\"><p class=\"nav-group-label\">Administration</p>\{render_navigation_item("/-/admin/settings/ssh", "Site settings", "settings", false)}</nav>"
      }
    }
    b <+
      "</div><div class=\"sidebar-footer\"><button class=\"nav-item sidebar-collapse\" type=\"button\" data-sidebar-collapse aria-controls=\"app-sidebar\" aria-expanded=\"true\" aria-label=\"Collapse sidebar\" title=\"Collapse sidebar\" hidden inert><span class=\"ui-icon\" data-icon=\"panel-left-close\" aria-hidden=\"true\"></span><span class=\"nav-label\">Collapse sidebar</span></button></div></aside><button class=\"sidebar-scrim\" type=\"button\" data-sidebar-close aria-label=\"Close navigation\" hidden></button>"
  })
}
