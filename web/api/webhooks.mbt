///|
fn hook_json(hook : @webhooks.Hook) -> Json {
  {
    "id": hook.id.to_string(),
    "url": hook.url,
    "events": hook.events.split(",").map(v => v.to_owned()).collect(),
    "active": hook.active,
    "version": hook.version.to_string(),
  }
}

///|
pub let webhooks_api_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let policy = ctx.require(@web_context.webhook_policy_key)
  ctx.get(
    "/repos/:owner/:repo/hooks",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      {
        "items": @webhooks.list_hooks(pool, actor, @web_context.repo_param(req)).map(
          hook_json,
        ),
      }
    }),
  )
  for updating in [false, true] {
    ctx.post(
      if updating {
        "/repos/:owner/:repo/hooks/:hook"
      } else {
        "/repos/:owner/:repo/hooks"
      },
      api_handler(req => {
        let actor = api_actor(pool, req, "write")
        let repo = @web_context.repo_param(req)
        ignore(@webhooks.require_manager(pool, actor, repo))
        let fields = api_body(req, [
          "url", "secret", "events", "active", "version",
        ])
        let id = if updating {
          number(@web_context.required_param(req, "hook", "webhook"))
        } else {
          0L
        }
        let expected = if updating {
          number(field(fields, "version"))
        } else {
          0L
        }
        guard fields.get("events") is Some(Array(events)) else {
          raise @domain.BadRequest(message="events array required")
        }
        let events = events.map(event => {
          match event {
            String(value) => value
            _ => raise @domain.BadRequest(message="event names must be strings")
          }
        })
        let active = match fields.get("active") {
          None => true
          Some(True) => true
          Some(False) => false
          _ => raise @domain.BadRequest(message="active must be boolean")
        }
        let id = @webhooks.save_hook(
          pool,
          actor,
          repo,
          id,
          expected,
          field(fields, "url"),
          field(fields, "secret", fallback=""),
          events,
          active,
          policy,
        )
        hook_json(@webhooks.get_hook(pool, actor, repo, id))
      }),
    )
  }
  ctx.get(
    "/repos/:owner/:repo/hooks/:hook/deliveries",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let rows = @webhooks.deliveries(
        pool,
        actor,
        @web_context.repo_param(req),
        number(@web_context.required_param(req, "hook", "webhook")),
        page=page(req),
      )
      {
        "items": rows.map(d => {
          (
            {
              "id": d.id.to_string(),
              "event_id": d.event_id.to_string(),
              "event": d.kind,
              "status": d.status,
              "attempts": d.attempts.to_string(),
              "response_code": d.response_code.to_string(),
              "error": d.error,
              "created_at": d.created_at,
              "next_attempt_at": d.next_attempt_at,
            } : Json)
        }),
        "has_more": rows.length() == 50,
      }
    }),
  )
  ctx.get(
    "/repos/:owner/:repo/hooks/:hook/deliveries/:delivery",
    api_handler(req => {
      @webhooks.delivery_detail(
        pool,
        api_actor(pool, req, "read"),
        @web_context.repo_param(req),
        number(@web_context.required_param(req, "hook", "webhook")),
        number(@web_context.required_param(req, "delivery", "delivery")),
      )
    }),
  )
  ctx.post(
    "/repos/:owner/:repo/hooks/:hook/deliveries/:delivery/redeliver",
    api_handler(req => {
      @webhooks.redeliver(
        pool,
        api_actor(pool, req, "write"),
        @web_context.repo_param(req),
        number(@web_context.required_param(req, "hook", "webhook")),
        number(@web_context.required_param(req, "delivery", "delivery")),
      )
      { "ok": true }
    }),
  )
  for action in ["ping", "delete"] {
    ctx.post(
      "/repos/:owner/:repo/hooks/:hook/" + action,
      api_handler(req => {
        let actor = api_actor(pool, req, "write")
        let repo = @web_context.repo_param(req)
        let id = number(@web_context.required_param(req, "hook", "webhook"))
        if action == "delete" {
          let body = api_body(req, ["version"])
          @webhooks.delete_hook(
            pool,
            actor,
            repo,
            id,
            number(field(body, "version")),
          )
        } else {
          @webhooks.ping(pool, actor, repo, id)
        }
        { "ok": true }
      }),
    )
  }
})
