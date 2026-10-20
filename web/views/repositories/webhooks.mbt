///|
pub let webhooks_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let assets = ctx.require(@web_context.asset_paths_key)
  let policy = ctx.require(@web_context.webhook_policy_key)
  ctx.get("/:owner/:repo/settings/webhooks", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    res.send_html(
      render_webhooks(
        assets,
        actor,
        repo,
        @webhooks.list_hooks(pool, actor, repo),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  for editing in [false, true] {
    ctx.get(
      if editing {
        "/:owner/:repo/settings/webhooks/:hook"
      } else {
        "/:owner/:repo/settings/webhooks/new"
      },
      async fn(req, res) {
        let actor = @web_context.require_current_user(req)
        let repo = @web_context.repo_param(req)
        let scope = @webhooks.require_manager(pool, actor, repo)
        let hook = if editing {
          @webhooks.get_hook(
            pool,
            actor,
            repo,
            @web_context.positive_resource_number(
              @web_context.required_param(req, "hook", "webhook"),
            ),
          )
        } else {
          @webhooks.Hook::{
            id: 0L,
            url: "",
            events: "push,merge_request,review,workflow_run",
            active: true,
            version: 0L,
          }
        }
        res.send_html(
          render_webhook_form(
            assets,
            actor,
            repo,
            hook,
            @web_context.request_form_token(req, "webhooks:\{scope.id}"),
            None,
          ),
          headers=@web_context.private_page_headers(),
        )
      },
    )
    ctx.post(
      if editing {
        "/:owner/:repo/settings/webhooks/:hook"
      } else {
        "/:owner/:repo/settings/webhooks"
      },
      async fn(req, res) {
        let actor = @web_context.require_current_user(req)
        let repo = @web_context.repo_param(req)
        let scope = @webhooks.require_manager(pool, actor, repo)
        let form = @web_context.protected_form(req, "webhooks:\{scope.id}")
        let id = if editing {
          @web_context.positive_resource_number(
            @web_context.required_param(req, "hook", "webhook"),
          )
        } else {
          0L
        }
        let version = if editing {
          @web_context.positive_resource_number(
            form.get("version").unwrap_or(""),
          )
        } else {
          0L
        }
        let events = @webhooks.event_kinds.filter(kind => {
          form.get("event_" + kind) == Some("1")
        })
        let hook : @webhooks.Hook = {
          id,
          url: form.get("url").unwrap_or(""),
          events: events.join(","),
          active: form.get("active") == Some("1"),
          version,
        }
        let saved = @webhooks.save_hook(
          pool,
          actor,
          repo,
          id,
          version,
          hook.url,
          form.get("secret").unwrap_or(""),
          events,
          hook.active,
          policy,
        ) catch {
          @domain.BadRequest(message~) => {
            res.send_html(
              render_webhook_form(
                assets,
                actor,
                repo,
                hook,
                @web_context.request_form_token(req, "webhooks:\{scope.id}"),
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
            location="\{@web_ui.repo_link(repo)}/settings/webhooks/\{saved}",
          ),
        )
      },
    )
  }
  ctx.get("/:owner/:repo/settings/webhooks/:hook/deliveries", async fn(
    req,
    res,
  ) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let scope = @webhooks.require_manager(pool, actor, repo)
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "hook", "webhook"),
    )
    let page = @web_context.positive_resource_number(
      req.query().get("page").unwrap_or("1"),
    )
    res.send_html(
      render_webhook_deliveries(
        assets,
        actor,
        repo,
        @webhooks.get_hook(pool, actor, repo, id),
        @webhooks.deliveries(pool, actor, repo, id, page~),
        page,
        @web_context.request_form_token(req, "webhooks:\{scope.id}"),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/:repo/settings/webhooks/:hook/deliveries/:delivery", async fn(
    req,
    res,
  ) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let id = @web_context.positive_resource_number(
      @web_context.required_param(req, "hook", "webhook"),
    )
    let delivery = @web_context.positive_resource_number(
      @web_context.required_param(req, "delivery", "delivery"),
    )
    let detail = @webhooks.delivery_detail(pool, actor, repo, id, delivery)
    res.send_html(
      @web_ui.layout(
        "Webhook delivery",
        assets,
        Html(b => {
          b <+
            "<section class=\"webhook-settings ssh-settings\"><a href=\"\{@web_ui.repo_link(repo)}/settings/webhooks/\{id.to_string()}/deliveries\">Deliveries</a><h1>Delivery #\{delivery.to_string()}</h1><p class=\"muted\">Payload and attempt history. Signing secrets and response bodies are never displayed.</p><pre class=\"webhook-payload\">\{detail.stringify(indent=2)}</pre></section>"
        }),
        current_user=Some(actor),
        navigation=@web_ui.RepositoryNavigation(repo, "webhooks", true),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  for action in ["ping", "delete", "redeliver"] {
    ctx.post("/:owner/:repo/settings/webhooks/:hook/" + action, async fn(
      req,
      res,
    ) {
      let actor = @web_context.require_current_user(req)
      let repo = @web_context.repo_param(req)
      let scope = @webhooks.require_manager(pool, actor, repo)
      let form = @web_context.protected_form(req, "webhooks:\{scope.id}")
      let id = @web_context.positive_resource_number(
        @web_context.required_param(req, "hook", "webhook"),
      )
      if action == "delete" {
        @webhooks.delete_hook(
          pool,
          actor,
          repo,
          id,
          @web_context.positive_resource_number(
            form.get("version").unwrap_or(""),
          ),
        )
      } else if action == "ping" {
        @webhooks.ping(pool, actor, repo, id)
      } else {
        @webhooks.redeliver(
          pool,
          actor,
          repo,
          id,
          @web_context.positive_resource_number(
            form.get("delivery").unwrap_or(""),
          ),
        )
      }
      res.send_void(
        status=303,
        headers=@web_context.private_page_headers(
          location="\{@web_ui.repo_link(repo)}/settings/webhooks" +
            (if action == "delete" {
              ""
            } else {
              "/\{id.to_string()}/deliveries"
            }),
        ),
      )
    })
  }
})
