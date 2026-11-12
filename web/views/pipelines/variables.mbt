///|
pub let repository_variables_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get("/:owner/:repo/settings/variables", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    let variables = @pipeline.list_variables(pool, actor, scope.repo)
    let manager = @identity.can_manage_team(pool, actor, scope.team_id)
    res.send_html(
      render_variables(
        assets,
        actor,
        scope.repo,
        variables,
        manager,
        req.query().get("saved") == Some("1"),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/:repo/settings/variables/new", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    require_pipeline_manager(pool, actor, scope)
    res.send_html(
      render_variable_form(
        assets,
        actor,
        scope.repo,
        @web_context.request_form_token(req, "repository-variables:\{scope.id}"),
        "",
        "",
        0L,
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  for action in ["edit", "delete"] {
    ctx.get("/:owner/:repo/settings/variables/:variable/" + action, async fn(
      req,
      res,
    ) {
      let actor = @web_context.require_current_user(req)
      let scope = pipeline_scope(pool, actor, req)
      require_pipeline_manager(pool, actor, scope)
      let name = @web_context.required_param(req, "variable", "variable").to_upper()
      let variable = @pipeline.list_variables(pool, actor, scope.repo)
        .iter()
        .find_first(variable => variable.name == name)
      guard variable is Some(variable) else {
        raise @domain.NotFound(message="Variable not found.")
      }
      let csrf = @web_context.request_form_token(
        req,
        "repository-variables:\{scope.id}",
      )
      res.send_html(
        if action == "edit" {
          render_variable_form(
            assets,
            actor,
            scope.repo,
            csrf,
            variable.name,
            variable.value,
            variable.version,
            None,
          )
        } else {
          render_variable_delete(assets, actor, scope.repo, csrf, variable)
        },
        headers=@web_context.private_page_headers(),
      )
    })
  }
  for
    route in [
      "/:owner/:repo/settings/variables", "/:owner/:repo/settings/variables/:variable",
    ] {
    ctx.post(route, async fn(req, res) {
      let actor = @web_context.require_current_user(req)
      let scope = pipeline_scope(pool, actor, req)
      require_pipeline_manager(pool, actor, scope)
      let csrf_scope = "repository-variables:\{scope.id}"
      // URL encoding expands each value byte by at most three characters.
      let form = @web_context.protected_form(req, csrf_scope, limit=163840)
      let name = req.params
        .get("variable")
        .map(value => value.to_owned())
        .unwrap_or(form.get("name").unwrap_or(""))
        .trim()
        .to_owned()
      let value = form.get("value").unwrap_or("")
      let version = @protocol.parse_decimal(form.get("version").unwrap_or("0"))
      guard version is Some(version) else {
        raise @domain.BadRequest(message="Invalid variable version.")
      }
      @pipeline.save_variable(pool, actor, scope.repo, name, value, version) catch {
        @domain.BadRequest(message~) | @pipeline.Conflict(message) => {
          res.send_html(
            render_variable_form(
              assets,
              actor,
              scope.repo,
              @web_context.request_form_token(req, csrf_scope),
              name,
              value,
              version,
              Some(message),
            ),
            status=400,
            headers=@web_context.private_page_headers(),
          )
          return
        }
        err => raise err
      }
      res.send_void(
        status=303,
        headers=@web_context.private_page_headers(
          location=@web_ui.repo_link(scope.repo) + "/settings/variables?saved=1",
        ),
      )
    })
  }
  ctx.post("/:owner/:repo/settings/variables/:variable/delete", async fn(
    req,
    res,
  ) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    require_pipeline_manager(pool, actor, scope)
    let form = @web_context.protected_form(
      req,
      "repository-variables:\{scope.id}",
    )
    @pipeline.delete_variable(
      pool,
      actor,
      scope.repo,
      @web_context.required_param(req, "variable", "variable"),
      @web_context.positive_resource_number(form.get("version").unwrap_or("")),
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location=@web_ui.repo_link(scope.repo) + "/settings/variables",
      ),
    )
  })
})

///|
fn render_variables(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  variables : Array[@pipeline.RepositoryVariable],
  manager : Bool,
  saved : Bool,
) -> @moonback.Html {
  let base = @web_ui.repo_link(repo) + "/settings/variables"
  @web_ui.layout(
    "Repository variables",
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings repository-variables\"><div class=\"page-heading page-heading--actions\"><div><h1>Repository variables</h1><p class=\"muted\">Nonsecret configuration for repository workflows.</p></div>"
      if manager {
        b <+ "<a class=\"button-link\" href=\"\{base}/new\">Add variable</a>"
      }
      b <+ "</div>"
      if saved {
        b <+ "<p class=\"flash-success\" role=\"status\">Variable saved.</p>"
      }
      b <+
        "<p>Values are visible to repository readers and are not masked in logs. Store credentials in secrets. New runs capture these values; existing runs and snapshot reruns keep their saved values.</p>"
      if variables.is_empty() {
        b <+
          "<p class=\"ssh-keys-empty muted\">No repository variables. Add configuration referenced with vars.NAME.</p>"
      } else {
        b <+ "<ul class=\"ssh-key-list\" aria-label=\"Repository variables\">"
        for variable in variables {
          b <+
            "<li class=\"ssh-key-item\"><div class=\"ssh-key-content\"><div class=\"ssh-key-heading\"><h2>\{variable.name}</h2></div><pre><code>\{variable.value}</code></pre><dl class=\"ssh-key-metadata\"><div><dt>Updated</dt><dd>\{@web_ui.timestamp(variable.updated_at)}</dd></div></dl>"
          if manager {
            b <+
              "<div class=\"ssh-form-actions\"><a href=\"\{base}/\{variable.name}/edit\" aria-label=\"Edit \{variable.name}\">Edit variable</a><a class=\"ssh-revoke-link\" href=\"\{base}/\{variable.name}/delete\" aria-label=\"Delete \{variable.name}\">Delete</a></div>"
          }
          b <+ "</div></li>"
        }
        b <+ "</ul>"
      }
      b <+ "</section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "variables", manager),
  )
}

///|
fn render_variable_form(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  csrf : String,
  name : String,
  value : String,
  version : Int64,
  error : String?,
) -> @moonback.Html {
  let base = @web_ui.repo_link(repo) + "/settings/variables"
  let heading = if version == 0L {
    "Add repository variable"
  } else {
    "Edit repository variable"
  }
  let action = if version == 0L { base } else { base + "/" + name.to_upper() }
  @web_ui.layout(
    heading,
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings ssh-settings--form repository-variable-form\"><nav class=\"ssh-settings-back\" aria-label=\"Settings\"><a href=\"\{base}\">Repository variables</a></nav><h1>\{heading}</h1>"
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"\{action}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{version.to_string()}\"><div class=\"field\"><label for=\"variable-name\">Name</label><input id=\"variable-name\" name=\"name\" value=\"\{name}\" maxlength=\"100\" pattern=\"[A-Za-z_][A-Za-z0-9_]*\" autocapitalize=\"characters\" spellcheck=\"false\" required"
      if version != 0L {
        b <+ " readonly"
      }
      b <+
        "></div><div class=\"field\"><label for=\"variable-value\">Value</label><textarea id=\"variable-value\" name=\"value\" rows=\"5\" maxlength=\"49152\" autocapitalize=\"none\" spellcheck=\"false\" aria-describedby=\"variable-value-help\">\{value}</textarea><p id=\"variable-value-help\" class=\"muted\">Up to 48 KiB of UTF-8 text; an empty value is allowed. Values are readable and are not secrets.</p></div><div class=\"ssh-form-actions\"><button type=\"submit\">\{if version == 0L { "Add variable" } else { "Save variable" }}</button><a href=\"\{base}\">Cancel</a></div></form></section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "variables", true),
  )
}

///|
fn render_variable_delete(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  csrf : String,
  variable : @pipeline.RepositoryVariable,
) -> @moonback.Html {
  let base = @web_ui.repo_link(repo) + "/settings/variables"
  @web_ui.layout(
    "Delete repository variable",
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings ssh-settings--form repository-variable-form\"><nav class=\"ssh-settings-back\" aria-label=\"Settings\"><a href=\"\{base}\">Repository variables</a></nav><h1>Delete repository variable</h1><p>Delete <strong>\{variable.name}</strong>? New runs will see an empty value for this name. Existing run snapshots retain the captured value.</p><form method=\"post\" action=\"\{base}/\{variable.name}/delete\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{variable.version.to_string()}\"><div class=\"ssh-form-actions\"><button type=\"submit\" class=\"ssh-danger-button\">Delete variable</button><a href=\"\{base}\">Cancel</a></div></form></section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "variables", true),
  )
}
