///|
pub let notifications_module : @moonback.Module = Module(ctx => {
  let assets = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get("/-/notifications", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let filter = req.query().get("filter").unwrap_or("unread")
    let page = match req.query().get("page") {
      Some(value) => @web_context.positive_resource_number(value)
      None => 1L
    }
    let settings = req.query().get("settings") == Some("1")
    let groups = if settings {
      []
    } else {
      @collaboration.inbox_groups(pool, actor, filter, page)
    }
    res.send_html(
      render_inbox(
        assets,
        actor,
        filter,
        page,
        groups,
        @collaboration.unread_notification_count(pool, actor),
        @collaboration.notification_email_enabled(pool, actor),
        @web_context.request_form_token(req, "notifications"),
        req.query().get("saved") == Some("1"),
        settings,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/-/notifications/count", async fn(req, res) {
    let count = @collaboration.unread_notification_count(
      pool,
      @web_context.require_current_user(req),
    )
    res.send_html(
      @moonback.Html(b => b <+ "\{count.to_string()}"),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/notifications/read-all", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let form = @web_context.protected_form(req, "notifications")
    @collaboration.mark_all_notifications_read(
      pool,
      actor,
      @web_context.positive_resource_number(form.get("through").unwrap_or("")),
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(location="/-/notifications"),
    )
  })
  ctx.post("/-/notifications/settings", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let form = @web_context.protected_form(req, "notifications")
    guard form.get("email") is (None | Some("on")) else {
      raise @domain.BadRequest(message="invalid email preference")
    }
    @collaboration.set_notification_email(
      pool,
      actor,
      form.get("email") == Some("on"),
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location="/-/notifications?settings=1&saved=1",
      ),
    )
  })
  ctx.post("/-/notifications/:id/read", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    ignore(@web_context.protected_form(req, "notifications"))
    let item = @collaboration.mark_notification_read(
      pool,
      actor,
      @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "notification"),
      ),
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(location=item.url()),
    )
  })
  ctx.post("/-/notifications/threads/:id", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let form = @web_context.protected_form(req, "notifications")
    let subscribed = match form.get("subscribed") {
      Some("1") => true
      Some("0") => false
      _ => raise @domain.BadRequest(message="invalid subscription")
    }
    let url = @collaboration.set_thread_subscription(
      pool,
      actor,
      @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "discussion"),
      ),
      subscribed,
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(location=url),
    )
  })
  ctx.post("/-/notifications/threads/:id/read", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let form = @web_context.protected_form(req, "notifications")
    let filter = form.get("filter").unwrap_or("unread")
    guard ["unread", "all", "reviews", "assigned"].contains(filter) else {
      raise @domain.BadRequest(message="invalid inbox filter")
    }
    let page = @web_context.positive_resource_number(
      form.get("page").unwrap_or("1"),
    )
    @collaboration.mark_thread_notifications_read(
      pool,
      actor,
      @web_context.positive_resource_number(
        @web_context.required_param(req, "id", "discussion"),
      ),
      @web_context.positive_resource_number(form.get("through").unwrap_or("")),
    )
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(
        location="/-/notifications?filter=\{filter}&page=\{page}",
      ),
    )
  })
})
