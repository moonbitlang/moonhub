///|
fn render_provider_workers(
  workers : Array[@protocol.WorkerView],
) -> @moonback.Html {
  let current = workers.filter(w => {
    !["drained", "failed"].contains(w.state) || w.active_attempts > 0
  })
  let history = workers.filter(w => {
    ["drained", "failed"].contains(w.state) && w.active_attempts == 0
  })
  Html(b => {
    b <+
      "<section class=\"provider-execution-workers\" aria-labelledby=\"provider-workers-heading\"><h2 id=\"provider-workers-heading\">Current workers (\{current.length().to_string()})</h2><ul class=\"mr-list\" data-current-workers>"
    for worker in current {
      b <+
        "<li><strong>\{worker.key}</strong><p class=\"muted\">\{worker.state} · configuration \{worker.applied_revision} · active tasks \{worker.active_attempts.to_string()}"
      if worker.draining && !["drained", "failed"].contains(worker.state) {
        b <+ " · draining"
      }
      b <+ "</p></li>"
    }
    if current.is_empty() {
      b <+ "<li class=\"muted\">No current workers.</li>"
    }
    b <+
      "</ul><details class=\"secondary-details provider-worker-history\"><summary><span class=\"ui-icon\" data-icon=\"chevron-right\" aria-hidden=\"true\"></span>Worker history (\{history.length().to_string()})</summary><p class=\"muted\">Recently registered workers that have stopped or failed. Cloud resource termination is tracked separately.</p><ul class=\"mr-list\" data-worker-history>"
    for worker in history {
      let state = if worker.state == "drained" { "Stopped" } else { "Failed" }
      b <+
        "<li><strong>\{worker.key}</strong><p class=\"muted\">\{state} · configuration \{worker.applied_revision}</p></li>"
    }
    if history.is_empty() {
      b <+ "<li class=\"muted\">No worker history.</li>"
    }
    b <+ "</ul></details></section>"
  })
}

///|
fn render_provider_config(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  control : @pipeline.ProviderControl,
  csrf : String,
  values : Map[String, String],
  error : String?,
) -> @moonback.Html {
  let snapshot = control.snapshot
  @web_ui.layout(
    "Provider execution settings",
    assets,
    Html(b => {
      b <+
        "<section class=\"repository-form\"><a href=\"/-/admin/pipelines/providers\">Pipeline providers</a><h1>Execution settings</h1><p class=\"page-subtitle\">\{snapshot.mode} · Provider #\{snapshot.id}</p>"
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<p class=\"settings-notice\" role=\"status\">Configuration \{snapshot.config_revision} · observed \{control.observed_revision.to_string()} · applied \{control.applied_revision.to_string()} · \{control.status}. Saving queues a configuration update. Existing tasks finish before execution settings change.</p>"
      if snapshot.mode.is_empty() {
        b <+ "<p>Connect moonhub-runner to configure execution settings.</p>"
      } else {
        b <+
          "<form class=\"form-stack\" method=\"post\" action=\"/-/admin/pipelines/providers/\{snapshot.id}/configuration\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"revision\" value=\"\{snapshot.config_revision}\">"
        for field in snapshot.schema {
          let value = values.get(field.name).unwrap_or("")
          let required = if field.required { " required" } else { "" }
          b <+
            "<div class=\"field\"><label for=\"config_\{field.name}\">\{field.title}</label>"
          if field.kind == "choice" {
            b <+
              "<select id=\"config_\{field.name}\" aria-describedby=\"help_\{field.name}\" name=\"config_\{field.name}\"\{required}>"
            if !field.required {
              b <+ "<option value=\"\">Not set</option>"
            }
            for choice in field.choices {
              b <+ "<option value=\"\{choice}\""
              if value == choice {
                b <+ " selected"
              }
              b <+ ">\{choice}</option>"
            }
            b <+ "</select>"
          } else if field.kind == "integer" {
            b <+
              "<input id=\"config_\{field.name}\" aria-describedby=\"help_\{field.name}\" name=\"config_\{field.name}\" type=\"number\" min=\"\{field.minimum.to_string()}\" max=\"\{field.maximum.to_string()}\" step=\"1\" value=\"\{value}\"\{required}>"
          } else {
            b <+
              "<input id=\"config_\{field.name}\" aria-describedby=\"help_\{field.name}\" name=\"config_\{field.name}\" value=\"\{value}\" maxlength=\"1024\"\{required} spellcheck=\"false\">"
          }
          b <+
            "<small id=\"help_\{field.name}\" class=\"muted\">\{field.help}</small></div>"
        }
        b <+ "<button type=\"submit\">Save configuration</button></form>"
      }
      b <+ "\{render_provider_workers(snapshot.workers)}</section>"
    }),
    current_user=Some(actor),
    head_end=@web_assets.repository_assets_head(assets),
    navigation=@web_ui.SiteNavigation("pipeline-providers"),
  )
}

///|
let provider_config_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  ctx.get("/-/admin/pipelines/providers/:id/configuration", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "id", "provider"),
    )
    let control = coordinator.provider_control(actor, id)
    res.send_html(
      render_provider_config(
        assets,
        actor,
        control,
        @web_context.request_form_token(req, "pipeline-providers"),
        control.snapshot.config,
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/admin/pipelines/providers/:id/configuration", async fn(
    req,
    res,
  ) {
    let actor = @web_context.require_current_user(req)
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "id", "provider"),
    )
    let control = coordinator.provider_control(actor, id)
    let form = @web_context.protected_form(req, "pipeline-providers")
    let revision = @protocol.parse_decimal(form.get("revision").unwrap_or(""))
    let values : Map[String, String] = Map([])
    for field in control.snapshot.schema {
      values[field.name] = form.get("config_" + field.name).unwrap_or("")
    }
    try {
      guard revision is Some(revision) else {
        raise @domain.BadRequest(
          message="Missing configuration revision. Reload before saving.",
        )
      }
      coordinator.save_provider_config(actor, id, revision, values)
    } catch {
      @pipeline.Conflict(message) => {
        res.send_html(
          render_provider_config(
            assets,
            actor,
            control,
            @web_context.request_form_token(req, "pipeline-providers"),
            control.snapshot.config,
            Some(message),
          ),
          status=409,
          headers=@web_context.private_page_headers(),
        )
        return
      }
      @domain.BadRequest(message~) => {
        res.send_html(
          render_provider_config(
            assets,
            actor,
            control,
            @web_context.request_form_token(req, "pipeline-providers"),
            values,
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
        location="/-/admin/pipelines/providers/" +
          id.to_string() +
          "/configuration",
      ),
    )
  })
})
