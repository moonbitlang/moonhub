///|
pub let ssh_keys_api_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get(
    "/user/ssh-keys",
    api_handler(req => {
      let actor = api_actor(pool, req, "ssh")
      {
        "items": @ssh.user_ssh_keys(pool, actor).map(key => {
          (
            {
              "id": key.id.to_string(),
              "title": key.title,
              "fingerprint": key.fingerprint,
              "created_at": key.created_at,
              "last_used_at": key.last_used_at
              .map(Json::string)
              .unwrap_or(Json::null()),
              "revoked_at": key.revoked_at
              .map(Json::string)
              .unwrap_or(Json::null()),
            } : Json)
        }),
      }
    }),
  )
  ctx.post(
    "/user/ssh-keys",
    api_handler(req => {
      ignore(api_actor(pool, req, "ssh"))
      let body = api_body(req, ["title", "public_key"])
      let title = field(body, "title").trim().to_owned()
      let key = @ssh.parse_ssh_public_key(field(body, "public_key"))
      // Body reads can suspend while the caller's credential is revoked.
      let actor = api_actor(pool, req, "ssh")
      let id = @ssh.add_ssh_key(pool, actor, title, key)
      { "id": id.to_string(), "title": title, "fingerprint": key.fingerprint }
    }),
  )
  ctx.post(
    "/user/ssh-keys/:id/revoke",
    api_handler(req => {
      ignore(api_actor(pool, req, "ssh"))
      let id = number(@web_context.required_param(req, "id", "SSH key"))
      ignore(api_body(req, [], body_limit=1024))
      let actor = api_actor(pool, req, "ssh")
      @ssh.revoke_own_ssh_key(pool, actor, id)
      { "id": id.to_string(), "revoked": true }
    }),
  )
})
