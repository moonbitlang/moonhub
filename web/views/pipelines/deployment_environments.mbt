///|
pub let deployment_environments_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  let assets = ctx.require(@web_context.asset_paths_key)
  ctx.get("/:owner/:repo/settings/environments", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    let items = @runtime.list_deployment_environments(pool, actor, scope.repo)
    let manager = @identity.can_manage_team(pool, actor, scope.team_id)
    let base = @web_ui.repo_link(scope.repo) + "/settings/environments"
    let csrf = @web_context.request_form_token(
      req,
      "deployment-settings:" + scope.id.to_string(),
    )
    res.send_html(
      @web_ui.layout(
        "Deployment environments",
        assets,
        Html(b => {
          b <+
            "<section class=\"ssh-settings\"><h1>Deployment environments</h1><p>Jobs wait for required reviewers before starting. Variables are visible configuration; secrets are delivered after approval. Reruns retain saved variables and require a new review.</p>"
          for item in items {
            b <+
              "<article class=\"ssh-key-item\"><h2>\{item.name}</h2><p>Reviewers: \{if item.reviewer_names.is_empty() { "No approval required" } else { item.reviewer_names.join(", ") }}</p>"
            if manager {
              b <+
                "<form method=\"post\" action=\"\{base}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"name\" value=\"\{item.name}\"><input type=\"hidden\" name=\"version\" value=\"\{item.version.to_string()}\"><label>Reviewers (usernames, separated by commas)<input name=\"reviewers\" value=\"\{item.reviewer_names.join(", ")}\"></label><button type=\"submit\">Save protection</button><button type=\"submit\" name=\"delete\" value=\"true\">Delete environment</button></form>"
            }
            for kind in ["variables", "secrets"] {
              b <+
                "<h3>\{if kind=="variables" {"Variables"} else {"Secrets"}}</h3>"
              let versions = if kind == "variables" {
                item.variable_versions
              } else {
                item.secrets
              }
              for name, version in versions {
                let value = if kind == "variables" {
                  item.variables.get(name).unwrap_or("")
                } else {
                  ""
                }
                if manager {
                  b <+
                    "<form method=\"post\" action=\"\{base}/\{item.name}/\{kind}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"\{version.to_string()}\"><input type=\"hidden\" name=\"name\" value=\"\{name}\"><label>\{name}"
                  if kind == "secrets" {
                    b <+
                      "<input name=\"value\" type=\"password\" autocomplete=\"new-password\" aria-label=\"New value for \{name}\">"
                  } else {
                    b <+ "<textarea name=\"value\">\{value}</textarea>"
                  }
                  b <+
                    "</label><button type=\"submit\">Save value</button><button type=\"submit\" name=\"delete\" value=\"true\">Delete value</button></form>"
                } else {
                  b <+ "<p><strong>\{name}</strong> \{value}</p>"
                }
              }
              if manager {
                b <+
                  "<form method=\"post\" action=\"\{base}/\{item.name}/\{kind}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"0\"><label>Name<input name=\"name\" required maxlength=\"100\"></label><label>Value"
                if kind == "secrets" {
                  b <+
                    "<input type=\"password\" name=\"value\" required autocomplete=\"new-password\">"
                } else {
                  b <+ "<textarea name=\"value\"></textarea>"
                }
                b <+
                  "</label><button type=\"submit\">Add \{if kind=="secrets" {"secret"}else{"variable"}}</button></form>"
              }
            }
            b <+ "</article>"
          }
          if manager {
            b <+
              "<h2>Add environment</h2><form method=\"post\" action=\"\{base}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"version\" value=\"0\"><label>Name<input name=\"name\" required maxlength=\"100\"></label><label>Reviewers (usernames, separated by commas)<input name=\"reviewers\"></label><button type=\"submit\">Add environment</button></form>"
          }
          b <+ "</section>"
        }),
        current_user=Some(actor),
        navigation=@web_ui.RepositoryNavigation(
          scope.repo,
          "variables",
          manager,
        ),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/:owner/:repo/settings/environments", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let scope = pipeline_scope(pool, actor, req)
    require_pipeline_manager(pool, actor, scope)
    let form = @web_context.protected_form(
      req,
      "deployment-settings:" + scope.id.to_string(),
    )
    let name = form.get("name").unwrap_or("").trim().to_owned()
    guard @protocol.parse_decimal(form.get("version").unwrap_or(""))
      is Some(version) else {
      raise @domain.BadRequest(message="Invalid environment version.")
    }
    if form.get("delete") == Some("true") {
      coordinator.delete_deployment_environment(
        actor,
        scope.repo,
        name,
        version,
      )
    } else {
      let reviewers : Array[Int64] = []
      for value in form.get("reviewers").unwrap_or("").split(",") {
        if !value.trim().is_empty() {
          reviewers.push(
            @identity.active_user_by_name(pool, value.trim().to_owned()).id,
          )
        }
      }
      coordinator.save_deployment_environment(
        actor,
        scope.repo,
        name,
        version,
        reviewers,
      )
    }
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location=@web_ui.repo_link(scope.repo) + "/settings/environments",
      ),
    )
  })
  for kind in ["variables", "secrets"] {
    ctx.post("/:owner/:repo/settings/environments/:environment/" + kind, async fn(
      req,
      res,
    ) {
      let actor = @web_context.require_current_user(req)
      let scope = pipeline_scope(pool, actor, req)
      require_pipeline_manager(pool, actor, scope)
      let form = @web_context.protected_form(
        req,
        "deployment-settings:" + scope.id.to_string(),
        limit=163840,
      )
      guard @protocol.parse_decimal(form.get("version").unwrap_or(""))
        is Some(version) else {
        raise @domain.BadRequest(message="Invalid value version.")
      }
      @runtime.save_deployment_value(
        pool,
        actor,
        scope.repo,
        @web_context.required_param(req, "environment", "environment"),
        form.get("name").unwrap_or(""),
        if form.get("delete") == Some("true") {
          None
        } else {
          Some(form.get("value").unwrap_or(""))
        },
        version,
        secret=kind == "secrets",
      )
      res.send_void(
        status=303,
        headers=@web_context.private_page_headers(
          location=@web_ui.repo_link(scope.repo) + "/settings/environments",
        ),
      )
    })
  }
  ctx.post("/:owner/:repo/pipelines/:number/deployments/:job", async fn(
    req,
    res,
  ) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let number = pipeline_number(req)
    let run = @runtime.get_run(pool, actor, repo, number)
    let form = @web_context.protected_form(
      req,
      "pipelines:" + run.id.to_string(),
    )
    coordinator.review_deployment(
      actor,
      repo,
      number,
      @web_context.positive_resource_number(
        @web_context.required_param(req, "job", "job"),
      ),
      @web_context.positive_resource_number(
        form.get("environment_id").unwrap_or(""),
      ),
      @web_context.positive_resource_number(
        form.get("policy_version").unwrap_or(""),
      ),
      form.get("decision").unwrap_or(""),
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location=@web_ui.repo_link(repo) + "/pipelines/" + number.to_string(),
      ),
    )
  })
})
