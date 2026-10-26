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
fn render_breadcrumbs(navigation : PageNavigation) -> @moonback.Html {
  Html(b => {
    b <+ "<nav class=\"breadcrumbs\" aria-label=\"Breadcrumb\">"
    match navigation {
      WorkspaceNavigation(section) =>
        b <+
          "<span>Workspace</span><span class=\"breadcrumb-separator\" aria-hidden=\"true\">/</span><strong>\{if section == "teams" { "Teams" } else if section == "notifications" { "Inbox" } else { "Repositories" }}</strong>"
      TeamNavigation(team, _) =>
        b <+
          "<a href=\"/-/teams\">Teams</a><span class=\"breadcrumb-separator\" aria-hidden=\"true\">/</span><strong>\{team.display_name}</strong>"
      PersonalNavigation(team) =>
        b <+
          "<span>Workspace</span><span class=\"breadcrumb-separator\" aria-hidden=\"true\">/</span><strong>\{team.display_name}</strong>"
      RepositoryNavigation(repo, _, _) =>
        b <+
          "<a href=\"/\{repo.owner}\">\{repo.owner}</a><span class=\"breadcrumb-separator\" aria-hidden=\"true\">/</span><a class=\"breadcrumb-current\" href=\"\{repo_link(repo)}\">\{repo.name}</a>"
      AccountNavigation(_) =>
        b <+
          "<span>Account</span><span class=\"breadcrumb-separator\" aria-hidden=\"true\">/</span><strong>Settings</strong>"
      SiteNavigation(_) =>
        b <+
          "<span>Administration</span><span class=\"breadcrumb-separator\" aria-hidden=\"true\">/</span><strong>Site settings</strong>"
    }
    b <+ "</nav>"
  })
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
    if !(navigation is RepositoryNavigation(_, _, _)) {
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
          "<nav class=\"nav-group context-navigation\" aria-label=\"Team\"><p class=\"nav-group-label\">\{team.display_name}</p>"
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
          "<nav class=\"nav-group context-navigation\" aria-label=\"Repository\"><p class=\"nav-group-label\">Repository</p>"
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
          ] {
          b <+
            "\{render_navigation_item(base + suffix, label, icon, active == key)}"
        }
        if manager {
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
