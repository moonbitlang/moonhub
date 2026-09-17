///|
fn requested_ssh_key_id(
  req : @moonback.Request,
) -> Int64 raise @domain.AppError {
  let id = @string.parse_int64(
    @web_context.required_param(req, "key", "SSH key"),
  ) catch {
    _ => raise @domain.NotFound(message="SSH key not found")
  }
  guard id > 0L else { raise @domain.NotFound(message="SSH key not found") }
  id
}

///|
pub let ssh_keys_module : @moonback.Module = Module(ctx => {
  let asset_path_map = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get("/-/settings/ssh-keys", async fn(req, res) {
    let user = @web_context.require_current_user(req)
    res.send_html(
      render_user_ssh_keys(asset_path_map, user, @ssh.user_ssh_keys(pool, user)),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/-/settings/ssh-keys/new", async fn(req, res) {
    let user = @web_context.require_current_user(req)
    res.send_html(
      render_new_ssh_key(
        asset_path_map,
        user,
        @web_context.request_form_token(req, "ssh-key-settings"),
        "",
        "",
        None,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/settings/ssh-keys", async fn(req, res) {
    let user = @web_context.require_current_user(req)
    let form = @web_context.protected_form(req, "ssh-key-settings")
    let title = form.get("title").unwrap_or("").trim().to_owned()
    let public_key = form.get("public_key").unwrap_or("")
    try {
      guard !public_key.contains("PRIVATE KEY") else {
        raise @domain.BadRequest(
          message="enter an Ed25519 public key, not a private key",
        )
      }
      let key = @ssh.parse_ssh_public_key(public_key)
      let _ = @ssh.add_ssh_key(pool, user, title, key)
    } catch {
      @domain.BadRequest(message~) => {
        res.send_html(
          render_new_ssh_key(
            asset_path_map,
            user,
            @web_context.request_form_token(req, "ssh-key-settings"),
            title,
            if public_key.contains("PRIVATE KEY") {
              ""
            } else {
              public_key
            },
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
      headers=@web_context.private_page_headers(location="/-/settings/ssh-keys"),
    )
  })
  ctx.get("/-/settings/ssh-keys/:key/revoke", async fn(req, res) {
    let user = @web_context.require_current_user(req)
    let key = @ssh.own_active_ssh_key(pool, user, requested_ssh_key_id(req))
    res.send_html(
      render_revoke_ssh_key(
        asset_path_map,
        user,
        @web_context.request_form_token(req, "ssh-key-settings"),
        key,
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/settings/ssh-keys/:key/revoke", async fn(req, res) {
    let user = @web_context.require_current_user(req)
    let _ = @web_context.protected_form(req, "ssh-key-settings")
    @ssh.revoke_own_ssh_key(pool, user, requested_ssh_key_id(req))
    res.send_void(
      status=303,
      headers=@web_context.private_page_headers(location="/-/settings/ssh-keys"),
    )
  })
})
