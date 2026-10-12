///|
pub fn layout(
  title : String,
  asset_path_map : Map[String, String],
  body : @moonback.Html,
  head_end~ : @moonback.Html = @moonback.Html::raw(""),
  body_class~ : String = "",
  current_user~ : @domain.CurrentUser? = None,
  navigation~ : PageNavigation = WorkspaceNavigation("repositories"),
) -> @moonback.Html {
  let stylesheet_head = @web_assets.app_styles_head(asset_path_map)
  let shell_script = @web_assets.vite_manifest_entry_path(
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
  current_user : @domain.CurrentUser?,
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
          "<a class=\"header-inbox\" href=\"/-/notifications\" aria-label=\"Inbox\" title=\"Inbox\"><span class=\"ui-icon\" data-icon=\"mail\" aria-hidden=\"true\"></span><span>Inbox</span><span class=\"count-badge\" data-inbox-count hidden></span></a>"
        b <+
          "<details class=\"account-menu\" data-dismissable><summary aria-label=\"Account menu\" title=\"Account menu\"><span class=\"avatar\" aria-hidden=\"true\">\{user.name_key[:1].to_owned().to_upper()}</span><span class=\"account-name\">\{user.display_name}</span><span class=\"ui-icon\" data-icon=\"chevron-down\" aria-hidden=\"true\"></span></summary><div class=\"account-menu-panel\"><div class=\"account-identity\"><strong>\{user.display_name}</strong><span>\{user.name_key}</span></div><a href=\"/-/settings/profile\"><span class=\"ui-icon\" data-icon=\"user\" aria-hidden=\"true\"></span>Profile</a><a href=\"/-/settings/ssh-keys\"><span class=\"ui-icon\" data-icon=\"key\" aria-hidden=\"true\"></span>SSH keys</a><a href=\"/-/change-password\"><span class=\"ui-icon\" data-icon=\"lock\" aria-hidden=\"true\"></span>Change password</a>"
        if user.is_site_admin {
          b <+
            "<a href=\"/-/admin/settings/ssh\" aria-label=\"Site settings\"><span class=\"ui-icon\" data-icon=\"settings\" aria-hidden=\"true\"></span>Site settings</a>"
        }
        b <+
          "<form class=\"logout-form\" method=\"post\" action=\"/-/logout\"><button class=\"logout-button\" type=\"submit\"><span class=\"ui-icon\" data-icon=\"log-out\" aria-hidden=\"true\"></span>Sign out</button></form></div></details>"
      }
      None => ()
    }
    b <+ "</div></header>"
  })
}

///|
pub fn repo_link(repo : @domain.RepoId) -> String {
  "/\{repo.path()}"
}

///|
pub fn render_repo_nav(
  repo : @domain.RepoId,
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
pub fn render_error(
  status : Int,
  message : String,
  asset_path_map : Map[String, String],
  current_user~ : @domain.CurrentUser? = None,
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
