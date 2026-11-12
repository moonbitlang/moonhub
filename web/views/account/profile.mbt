///|
pub let profile_module : @moonback.Module = Module(ctx => {
  let asset_path_map = ctx.require(@web_context.asset_paths_key)
  let pool = ctx.require(@web_context.config_db_pool)
  ctx.get("/-/settings/profile", async fn(req, res) {
    let user = @web_context.require_current_user(req)
    let profile = @identity.user_profile(pool, user)
    res.send_html(
      render_profile_settings(
        asset_path_map,
        user,
        profile,
        @web_context.request_form_token(req, "profile-settings"),
        profile.display_name,
        profile.time_zone.unwrap_or(""),
        None,
        req.query().get("saved") == Some("1"),
      ),
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.post("/-/settings/profile", async fn(req, res) {
    let user = @web_context.require_current_user(req)
    let form = @web_context.protected_form(req, "profile-settings")
    let display_name = form.get("display_name").unwrap_or("").trim().to_owned()
    let profile = @identity.user_profile(pool, user)
    // Older clients may submit only a display name. Preserve their preference.
    let time_zone = form
      .get("time_zone")
      .unwrap_or(profile.time_zone.unwrap_or(""))
      .trim()
      .to_owned()
    let preference = if time_zone.is_empty() { None } else { Some(time_zone) }
    let invalid = if display_name.is_empty() {
      Some("display name is required")
    } else if display_name.length() > 100 {
      Some("display name must be 100 characters or fewer")
    } else if !display_name
      .iter()
      .all(ch => ch.to_int() >= 32 && ch.to_int() != 127) {
      Some("display name cannot contain control characters")
    } else if !@identity.valid_display_time_zone(preference) {
      Some("Choose a valid display time zone.")
    } else {
      None
    }
    match invalid {
      Some(message) =>
        res.send_html(
          render_profile_settings(
            asset_path_map,
            user,
            profile,
            @web_context.request_form_token(req, "profile-settings"),
            display_name,
            time_zone,
            Some(message),
            false,
          ),
          status=400,
          headers=@web_context.private_page_headers(),
        )
      None => {
        @identity.update_profile(pool, user, display_name, preference)
        res.send_void(
          status=303,
          headers=@web_context.private_page_headers(
            location="/-/settings/profile?saved=1",
          ),
        )
      }
    }
  })
})
