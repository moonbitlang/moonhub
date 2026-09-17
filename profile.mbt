///|
struct UserProfile {
  name_key : String
  display_name : String
  email : String?
}

///|
fn user_profile(pool : Database, actor : CurrentUser) -> UserProfile raise {
  pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT name_key, display_name, email
        #|FROM "user"
        #|WHERE id = ?
      ),
      params=[actor.id],
    )
    guard row is Some(row) else { raise NotFound(message="account not found") }
    {
      name_key: row.get_name("name_key"),
      display_name: row.get_name("display_name"),
      email: row.get_name("email"),
    }
  })
}

///|
fn update_display_name(
  pool : Database,
  actor : CurrentUser,
  display_name : String,
) -> Unit raise {
  pool.with_client(client => {
    client.with_transaction(tx => {
      let changed = tx.execute(
        (
          #|UPDATE "user"
          #|SET display_name = ?, updated_at = datetime('now')
          #|WHERE id = ?
        ),
        params=[display_name, actor.id],
      )
      guard changed == 1 else { raise NotFound(message="account not found") }
      // The personal namespace of an account carries its display name.
      let _ = tx.execute(
        (
          #|UPDATE team
          #|SET display_name = ?, updated_at = datetime('now')
          #|WHERE name_key = ? AND kind = 'personal'
        ),
        params=[display_name, actor.name_key],
      )
    })
  })
}

///|
fn profile_module(asset_path_map : Map[String, String]) -> @moonback.Module {
  Module(ctx => {
    let pool = db_pool(ctx)
    ctx.get("/-/settings/profile", async fn(req, res) {
      let user = require_current_user(req)
      let profile = user_profile(pool, user)
      res.send_html(
        render_profile_settings(
          asset_path_map,
          user,
          profile,
          request_form_token(req, "profile-settings"),
          profile.display_name,
          None,
          req.query().get("saved") == Some("1"),
        ),
        headers=private_page_headers(),
      )
    })
    ctx.post("/-/settings/profile", async fn(req, res) {
      let user = require_current_user(req)
      let form = protected_form(req, "profile-settings")
      let display_name = form
        .get("display_name")
        .unwrap_or("")
        .trim()
        .to_owned()
      let invalid = if display_name.is_empty() {
        Some("display name is required")
      } else if display_name.length() > 100 {
        Some("display name must be 100 characters or fewer")
      } else if !display_name
        .iter()
        .all(ch => ch.to_int() >= 32 && ch.to_int() != 127) {
        Some("display name cannot contain control characters")
      } else {
        None
      }
      match invalid {
        Some(message) =>
          res.send_html(
            render_profile_settings(
              asset_path_map,
              user,
              user_profile(pool, user),
              request_form_token(req, "profile-settings"),
              display_name,
              Some(message),
              false,
            ),
            status=400,
            headers=private_page_headers(),
          )
        None => {
          update_display_name(pool, user, display_name)
          res.send_void(
            status=303,
            headers=private_page_headers(location="/-/settings/profile?saved=1"),
          )
        }
      }
    })
  })
}
