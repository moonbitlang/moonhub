///|
struct UserSshKey {
  id : Int64
  title : String
  fingerprint : String
  created_at : String
  last_used_at : String?
  revoked_at : String?
}

///|
fn user_ssh_keys(
  pool : Database,
  user : CurrentUser,
) -> Array[UserSshKey] raise {
  pool.with_client(client => {
    client
    .query_all(
      (
        #|SELECT id, title, fingerprint, created_at, last_used_at, revoked_at
        #|FROM ssh_key WHERE user_id = ?
        #|ORDER BY (revoked_at IS NOT NULL), id DESC
      ),
      params=[user.id],
    )
    .map(row => {
      id: row.get_name("id"),
      title: row.get_name("title"),
      fingerprint: row.get_name("fingerprint"),
      created_at: row.get_name("created_at"),
      last_used_at: row.get_name("last_used_at"),
      revoked_at: row.get_name("revoked_at"),
    })
  })
}

///|
fn own_active_ssh_key(
  pool : Database,
  user : CurrentUser,
  id : Int64,
) -> UserSshKey raise {
  pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT id, title, fingerprint, created_at, last_used_at, revoked_at
        #|FROM ssh_key WHERE id = ? AND user_id = ? AND revoked_at IS NULL
      ),
      params=[id, user.id],
    )
    guard row is Some(row) else { raise NotFound(message="SSH key not found") }
    {
      id: row.get_name("id"),
      title: row.get_name("title"),
      fingerprint: row.get_name("fingerprint"),
      created_at: row.get_name("created_at"),
      last_used_at: row.get_name("last_used_at"),
      revoked_at: row.get_name("revoked_at"),
    }
  })
}

///|
fn revoke_own_ssh_key(
  pool : Database,
  user : CurrentUser,
  id : Int64,
) -> Unit raise {
  let changed = pool.with_client(client => {
    client.execute(
      (
        #|UPDATE ssh_key SET revoked_at = datetime('now')
        #|WHERE id = ? AND user_id = ? AND revoked_at IS NULL
      ),
      params=[id, user.id],
    )
  })
  guard changed == 1 else { raise NotFound(message="SSH key not found") }
}

///|
fn requested_ssh_key_id(req : @moonback.Request) -> Int64 raise AppError {
  let id = @string.parse_int64(req.required_param("key", "SSH key")) catch {
    _ => raise NotFound(message="SSH key not found")
  }
  guard id > 0L else { raise NotFound(message="SSH key not found") }
  id
}

///|
fn ssh_keys_module(asset_path_map : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    ctx.get("/settings/ssh-keys", async fn(req, res) {
      let user = require_current_user(req)
      res.send_html(
        render_user_ssh_keys(asset_path_map, user, user_ssh_keys(pool, user)),
        headers=private_page_headers(),
      )
    })
    ctx.get("/settings/ssh-keys/new", async fn(req, res) {
      let user = require_current_user(req)
      res.send_html(
        render_new_ssh_key(
          asset_path_map,
          user,
          request_form_token(req, "ssh-key-settings"),
          "",
          "",
          None,
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/settings/ssh-keys", async fn(req, res) {
      let user = require_current_user(req)
      let form = protected_form(req, "ssh-key-settings")
      let title = form.get("title").unwrap_or("").trim().to_owned()
      let public_key = form.get("public_key").unwrap_or("")
      try {
        guard !public_key.contains("PRIVATE KEY") else {
          raise BadRequest(
            message="enter an Ed25519 public key, not a private key",
          )
        }
        let key = parse_ssh_public_key(public_key)
        let _ = add_ssh_key(pool, user, title, key)
      } catch {
        BadRequest(message~) => {
          res.send_html(
            render_new_ssh_key(
              asset_path_map,
              user,
              request_form_token(req, "ssh-key-settings"),
              title,
              if public_key.contains("PRIVATE KEY") {
                ""
              } else {
                public_key
              },
              Some(message),
            ),
            status=400,
            headers=private_page_headers(),
          )
          return
        }
        err => raise err
      }
      res.send_void(
        status=303,
        headers=private_page_headers(location="/settings/ssh-keys"),
      )
    })
    ctx.get("/settings/ssh-keys/:key/revoke", async fn(req, res) {
      let user = require_current_user(req)
      let key = own_active_ssh_key(pool, user, requested_ssh_key_id(req))
      res.send_html(
        render_revoke_ssh_key(
          asset_path_map,
          user,
          request_form_token(req, "ssh-key-settings"),
          key,
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/settings/ssh-keys/:key/revoke", async fn(req, res) {
      let user = require_current_user(req)
      let _ = protected_form(req, "ssh-key-settings")
      revoke_own_ssh_key(pool, user, requested_ssh_key_id(req))
      res.send_void(
        status=303,
        headers=private_page_headers(location="/settings/ssh-keys"),
      )
    })
  })
}
