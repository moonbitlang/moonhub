///|
fn render_runner_group_form(
  name : String,
  revision : String,
  providers : String,
  repositories : String,
  csrf : String,
) -> @moonback.Html {
  Html(b => {
    b <+
      "<form class=\"form-stack\" method=\"post\" action=\"/-/admin/pipelines/groups\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"revision\" value=\"\{revision}\">"
    if revision == "0" {
      b <+
        "<label class=\"field\"><span>Group name</span><input name=\"name\" value=\"\{name}\" required maxlength=\"64\" pattern=\"[A-Za-z_][A-Za-z0-9_-]*\"></label>"
    } else {
      b <+ "<input type=\"hidden\" name=\"name\" value=\"\{name}\">"
    }
    b <+
      "<label class=\"field\"><span>Provider names</span><input name=\"providers\" value=\"\{providers}\" maxlength=\"6500\"><small>Comma-separated registered provider names.</small></label><label class=\"field\"><span>Authorized repositories</span><input name=\"repositories\" value=\"\{repositories}\" maxlength=\"13000\"><small>Comma-separated owner/repository names. Leaving this empty prevents the group from running jobs.</small></label><button type=\"submit\">Save group</button></form>"
  })
}

///|
fn render_runner_groups(
  assets : Map[String, String],
  actor : @domain.CurrentUser,
  groups : Array[@runtime.RunnerGroup],
  providers : Array[@runtime.Provider],
  csrf : String,
  submitted : Map[String, String],
  error : String?,
) -> @moonback.Html {
  @web_ui.layout(
    "Runner groups",
    assets,
    Html(b => {
      b <+
        "<div class=\"page-heading\"><div><a href=\"/-/admin/pipelines/providers\">Pipeline providers</a><h1>Runner groups</h1><p class=\"page-subtitle\">Select provider pools with runs-on.group. Jobs must also match the requested labels and each provider's repository access.</p></div></div>"
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<p>Available providers: \{providers.filter(p => !p.revoked).map(p => p.name).join(", ")}</p>"
      for group in groups {
        let editing = error is Some(_) &&
          submitted.get("name") == Some(group.name)
        let names = group.providers
          .map(id => {
            providers
            .iter()
            .find_first(p => p.id == id)
            .map(p => p.name)
            .unwrap_or("")
          })
          .join(",")
        b <+
          "<section class=\"repository-form\"><h2>\{group.name}</h2>\{render_runner_group_form(group.name, if editing { submitted.get("revision").unwrap_or("") } else { group.revision.to_string() }, if editing { submitted.get("providers").unwrap_or("") } else { names }, if editing { submitted.get("repositories").unwrap_or("") } else { group.repositories.join(",") }, csrf)}</section>"
      }
      let creating = error is Some(_) && submitted.get("revision") == Some("0")
      b <+
        "<section class=\"repository-form\"><h2>New group</h2>\{render_runner_group_form(if creating { submitted.get("name").unwrap_or("") } else { "" }, "0", if creating { submitted.get("providers").unwrap_or("") } else { "" }, if creating { submitted.get("repositories").unwrap_or("") } else { "" }, csrf)}</section>"
    }),
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(actor),
    navigation=@web_ui.SiteNavigation("pipeline-providers"),
  )
}

///|
let runner_groups_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  ctx.get("/-/admin/pipelines/groups", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    res.send_html(
      render_runner_groups(
        assets,
        actor,
        coordinator.runner_groups(actor),
        coordinator.list_providers(actor),
        @web_context.request_form_token(req, "pipeline-providers"),
        Map([]),
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/admin/pipelines/groups", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let groups = coordinator.runner_groups(actor)
    let providers = coordinator.list_providers(actor)
    let form = @web_context.protected_form(req, "pipeline-providers")
    let failure = try {
      guard @protocol.parse_decimal(form.get("revision").unwrap_or(""))
        is Some(revision) else {
        raise @domain.BadRequest(
          message="Missing configuration revision. Reload before saving.",
        )
      }
      let selected = form
        .get("providers")
        .unwrap_or("")
        .split(",")
        .filter(name => !name.trim().is_empty())
        .collect()
        .map(name => {
          guard providers
            .iter()
            .find_first(p => p.name == name.trim().to_owned() && !p.revoked)
            is Some(provider) else {
            raise @domain.BadRequest(
              message="Select active registered provider names.",
            )
          }
          provider.id
        })
      let (_, repositories) = parse_provider_access(
        "selected",
        form.get("repositories").unwrap_or(""),
      )
      coordinator.save_runner_group(
        actor,
        form.get("name").unwrap_or(""),
        revision,
        selected,
        repositories,
      )
      None
    } catch {
      @runtime.Conflict(message) => Some((409, message))
      @domain.BadRequest(message~) => Some((400, message))
      err => raise err
    }
    if failure is Some((status, message)) {
      res.send_html(
        render_runner_groups(
          assets,
          actor,
          groups,
          providers,
          @web_context.request_form_token(req, "pipeline-providers"),
          form,
          Some(message),
        ),
        status~,
        headers=@web_context.private_page_headers(),
      )
    } else {
      res.send_text("", status=303, headers={
        "location": "/-/admin/pipelines/groups",
      })
    }
  })
})
