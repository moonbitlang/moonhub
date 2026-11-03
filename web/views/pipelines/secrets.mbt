///|
pub let repository_secrets_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  ctx.get("/:owner/:repo/settings/secrets", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let secrets = @pipeline.list_secrets(pool, actor, repo)
    res.send_html(
      render_secrets(
        assets,
        actor,
        repo,
        secrets,
        req.query().get("saved") == Some("1"),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/:repo/settings/secrets/new", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    require_pipeline_manager(pool, actor, scope)
    res.send_html(
      render_secret_form(
        assets,
        actor,
        scope.repo,
        @web_context.request_form_token(req, "repository-secrets:\{scope.id}"),
        "",
        "",
        ".github/workflows/publish.yml",
        0L,
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  for action in ["edit", "delete"] {
    ctx.get("/:owner/:repo/settings/secrets/:secret/" + action, async fn(
      req,
      res,
    ) {
      let actor = @web_context.require_current_user(req)
      let scope = pipeline_scope(pool, actor, req)
      let name = @web_context.required_param(req, "secret", "secret").to_upper()
      let secret = @pipeline.list_secrets(pool, actor, scope.repo)
        .iter()
        .find_first(secret => secret.name == name)
      guard secret is Some(secret) else {
        raise @domain.NotFound(message="Secret not found.")
      }
      let csrf = @web_context.request_form_token(
        req,
        "repository-secrets:\{scope.id}",
      )
      res.send_html(
        if action == "edit" {
          render_secret_form(
            assets,
            actor,
            scope.repo,
            csrf,
            secret.name,
            secret.branch,
            secret.workflow_path,
            secret.version,
            None,
          )
        } else {
          render_secret_delete(assets, actor, scope.repo, csrf, secret)
        },
        headers=@web_context.private_page_headers(),
      )
    })
  }
  for
    route in [
      "/:owner/:repo/settings/secrets", "/:owner/:repo/settings/secrets/:secret",
    ] {
    ctx.post(route, async fn(req, res) {
      let actor = @web_context.require_current_user(req)
      let scope = pipeline_scope(pool, actor, req)
      require_pipeline_manager(pool, actor, scope)
      let csrf_scope = "repository-secrets:\{scope.id}"
      let form = @web_context.protected_form(req, csrf_scope)
      let name = req.params
        .get("secret")
        .map(value => value.to_owned())
        .unwrap_or(form.get("name").unwrap_or(""))
        .trim()
        .to_owned()
      let branch = form.get("branch").unwrap_or("").trim().to_owned()
      let workflow = form.get("workflow").unwrap_or("").trim().to_owned()
      let version = @protocol.parse_decimal(form.get("version").unwrap_or("0"))
      guard version is Some(version) else {
        raise @domain.BadRequest(message="Invalid secret version.")
      }
      @pipeline.save_secret(
        pool,
        root,
        actor,
        scope.repo,
        name,
        form.get("value").filter(value => !value.is_empty()),
        branch,
        workflow,
        version,
      ) catch {
        @domain.BadRequest(message~) | @pipeline.Conflict(message) => {
          res.send_html(
            render_secret_form(
              assets,
              actor,
              scope.repo,
              @web_context.request_form_token(req, csrf_scope),
              name,
              branch,
              workflow,
              version,
              Some(
                message + " Re-enter the secret value if you were replacing it.",
              ),
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
          location=@web_ui.repo_link(scope.repo) + "/settings/secrets?saved=1",
        ),
      )
    })
  }
  ctx.post("/:owner/:repo/settings/secrets/:secret/delete", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    require_pipeline_manager(pool, actor, scope)
    let form = @web_context.protected_form(
      req,
      "repository-secrets:\{scope.id}",
    )
    let version = @web_context.positive_resource_number(
      form.get("version").unwrap_or(""),
    )
    @pipeline.delete_secret(
      pool,
      actor,
      scope.repo,
      @web_context.required_param(req, "secret", "secret"),
      version,
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location=@web_ui.repo_link(scope.repo) + "/settings/secrets",
      ),
    )
  })
})

///|
fn render_secrets(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  secrets : Array[@pipeline.RepositorySecret],
  saved : Bool,
) -> @moonback.Html {
  let base = @web_ui.repo_link(repo) + "/settings/secrets"
  @web_ui.layout(
    "Repository secrets",
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings repository-secrets\"><div class=\"page-heading page-heading--actions\"><div><h1>Repository secrets</h1><p class=\"muted\">Credentials for selected pipeline workflows.</p></div><a class=\"button-link\" href=\"\{base}/new\">Add secret</a></div>"
      if saved {
        b <+ "<p class=\"flash-success\" role=\"status\">Secret saved.</p>"
      }
      b <+
        "<p>Each secret is limited to one branch and workflow. Merge request checks cannot use secrets. Saved values are never displayed.</p>"
      if secrets.is_empty() {
        b <+
          "<p class=\"ssh-keys-empty muted\">No repository secrets. Add a secret to pass credentials to a workflow.</p>"
      } else {
        b <+ "<ul class=\"ssh-key-list\" aria-label=\"Repository secrets\">"
        for secret in secrets {
          b <+
            "<li class=\"ssh-key-item\"><div class=\"ssh-key-content\"><div class=\"ssh-key-heading\"><h2>\{secret.name}</h2></div><dl class=\"ssh-key-metadata\"><div><dt>Branch</dt><dd>\{secret.branch}</dd></div><div><dt>Workflow</dt><dd>\{secret.workflow_path}</dd></div><div><dt>Updated</dt><dd>\{secret.updated_at} UTC</dd></div></dl><div class=\"ssh-form-actions\"><a href=\"\{base}/\{secret.name}/edit\" aria-label=\"Edit \{secret.name}\">Edit secret</a><a class=\"ssh-revoke-link\" href=\"\{base}/\{secret.name}/delete\" aria-label=\"Delete \{secret.name}\">Delete</a></div></div></li>"
        }
        b <+ "</ul>"
      }
      b <+ "</section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "secrets", true),
  )
}

///|
fn render_secret_form(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  csrf : String,
  name : String,
  branch : String,
  workflow : String,
  version : Int64,
  error : String?,
) -> @moonback.Html {
  let base = @web_ui.repo_link(repo) + "/settings/secrets"
  let heading = if version == 0L {
    "Add repository secret"
  } else {
    "Edit repository secret"
  }
  let action = if version == 0L { base } else { base + "/" + name.to_upper() }
  @web_ui.layout(
    heading,
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings ssh-settings--form repository-secret-form\"><nav class=\"ssh-settings-back\" aria-label=\"Settings\"><a href=\"\{base}\">Repository secrets</a></nav><h1>\{heading}</h1>"
      if error is Some(error) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{error}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"\{action}\" autocomplete=\"off\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{version.to_string()}\"><div class=\"field\"><label for=\"secret-name\">Name</label><input id=\"secret-name\" name=\"name\" value=\"\{name}\" maxlength=\"100\" pattern=\"[A-Za-z_][A-Za-z0-9_]*\" autocapitalize=\"characters\" spellcheck=\"false\" required"
      if version != 0L {
        b <+ " readonly"
      }
      b <+
        "></div><div class=\"field\"><label for=\"secret-value\">\{if version == 0L { "Value" } else { "New value" }}</label><textarea id=\"secret-value\" name=\"value\" rows=\"5\" maxlength=\"16384\" autocomplete=\"off\" autocapitalize=\"none\" spellcheck=\"false\" aria-describedby=\"secret-value-help\""
      if version == 0L {
        b <+ " required"
      }
      b <+
        "></textarea><p id=\"secret-value-help\" class=\"muted\">\{if version == 0L { "Up to 16 KiB. Saved values cannot be viewed." } else { "Leave blank to keep the current value. Enter a new value to rotate the secret." }}</p></div><div class=\"field\"><label for=\"secret-branch\">Allowed branch</label><input id=\"secret-branch\" name=\"branch\" value=\"\{branch}\" maxlength=\"200\" spellcheck=\"false\" required><p class=\"muted\">An existing branch name, such as master. Exact names only.</p></div><div class=\"field\"><label for=\"secret-workflow\">Allowed workflow</label><input id=\"secret-workflow\" name=\"workflow\" value=\"\{workflow}\" maxlength=\"240\" spellcheck=\"false\" required><p class=\"muted\">The complete path under .github/workflows/. Manual and push runs only.</p></div><div class=\"ssh-form-actions\"><button type=\"submit\">\{if version == 0L { "Add secret" } else { "Save secret" }}</button><a href=\"\{base}\">Cancel</a></div></form></section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "secrets", true),
  )
}

///|
fn render_secret_delete(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  csrf : String,
  secret : @pipeline.RepositorySecret,
) -> @moonback.Html {
  let base = @web_ui.repo_link(repo) + "/settings/secrets"
  @web_ui.layout(
    "Delete repository secret",
    assets,
    Html(b => {
      b <+
        "<section class=\"ssh-settings ssh-settings--form repository-secret-form\"><nav class=\"ssh-settings-back\" aria-label=\"Settings\"><a href=\"\{base}\">Repository secrets</a></nav><h1>Delete repository secret</h1><p>Delete <strong>\{secret.name}</strong>? Future steps that need this secret will fail. A step that already received the value can continue using it.</p><form method=\"post\" action=\"\{base}/\{secret.name}/delete\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{secret.version.to_string()}\"><div class=\"ssh-form-actions\"><button type=\"submit\" class=\"ssh-danger-button\">Delete secret</button><a href=\"\{base}\">Cancel</a></div></form></section>"
    }),
    current_user=Some(actor),
    navigation=@web_ui.RepositoryNavigation(repo, "secrets", true),
  )
}
