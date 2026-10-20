///|
pub let attachments_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  ctx.post(
    "/:owner/:repo/attachments",
    image_request((req, res) => {
      @web_context.authorize_image_form(req)
      let actor = @web_context.require_current_user(req)
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      @repository.authorize_repository(pool, actor, scope.repo, Write)
      let bytes = @web_context.read_bounded_body(
        req, @image_store.maximum_attachment_bytes,
      )
      let image = @image_store.upload(
        pool,
        root,
        scope,
        actor,
        req.query().get("filename").unwrap_or("attachment"),
        bytes,
      )
      res.send_json(
        {
          "id": image.id,
          "url": image.url,
          "filename": image.filename,
          "markdown": @image_store.markdown(image),
          "media_type": image.media_type,
          "byte_size": image.byte_size.to_string(),
        },
        headers={ "Cache-Control": "no-store" },
      )
    }),
  )
  ctx.get("/:owner/:repo/attachments/:id", (req, res) => {
    let actor = @web_context.require_current_user(req)
    let scope = @repository.repository_scope(
      pool,
      actor,
      @web_context.repo_param(req),
    )
    let download = @image_store.read(
      pool,
      root,
      scope,
      actor,
      @web_context.required_param(req, "id", "attachment"),
    )
    let writer = res.respond(headers={
      "Content-Type": download.media_type,
      "Content-Length": download.bytes.length().to_string(),
      "Cache-Control": "private, no-store",
      "X-Content-Type-Options": "nosniff",
      "Content-Disposition": @web_context.attachment_disposition(
        download.filename,
        inline=download.media_type != "application/octet-stream",
      ),
      "Content-Security-Policy": "default-src 'none'; sandbox",
    })
    writer.write(download.bytes)
  })
  ctx.post(
    "/:owner/:repo/markdown-preview",
    image_request((req, res) => {
      @web_context.authorize_image_form(req)
      let actor = @web_context.require_current_user(req)
      let scope = @repository.repository_scope(
        pool,
        actor,
        @web_context.repo_param(req),
      )
      @repository.authorize_repository(pool, actor, scope.repo, Write)
      let bytes = @web_context.read_bounded_body(req, 80000)
      let text = @utf8.decode(bytes) catch {
        _ => raise @domain.BadRequest(message="invalid UTF-8 Markdown")
      }
      guard text.length() <= 20000 else {
        raise @domain.BadRequest(
          message="Markdown must contain at most 20000 characters",
        )
      }
      res.send_html(@web_ui.markdown(text), headers={
        "Cache-Control": "no-store",
      })
    }),
  )
})

///|
fn image_request(handler : @moonback.Handler) -> @moonback.Handler {
  (req, res) => {
    handler(req, res) catch {
      @domain.BadRequest(message~) =>
        res.send_json({ "error": { "message": message } }, status=400, headers={
          "Cache-Control": "no-store",
          "Connection": "close",
        })
      @domain.Forbidden(message~) =>
        res.send_json({ "error": { "message": message } }, status=403, headers={
          "Cache-Control": "no-store",
          "Connection": "close",
        })
      @domain.NotFound(message~) =>
        res.send_json({ "error": { "message": message } }, status=404, headers={
          "Cache-Control": "no-store",
          "Connection": "close",
        })
      err => raise err
    }
  }
}
