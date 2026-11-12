///|
fn render_profile_settings(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  profile : @identity.UserProfile,
  csrf : String,
  display_name : String,
  time_zone : String,
  error : String?,
  saved : Bool,
) -> @moonback.Html {
  @web_ui.layout(
    "Profile",
    assets,
    Html(b => {
      b <+ "<section class=\"panel profile-settings\"><h1>Profile</h1>"
      if saved {
        b <+ "<p class=\"settings-success\" role=\"status\">Profile saved.</p>"
      }
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"/-/settings/profile\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\">"
      b <+
        "<div class=\"field\"><label for=\"profile-name-key\"><span>Username</span></label><input id=\"profile-name-key\" class=\"path\" value=\"\{profile.name_key}\" readonly aria-describedby=\"profile-name-key-note\"></div><p id=\"profile-name-key-note\" class=\"muted\">Usernames identify repository namespaces and cannot be changed.</p>"
      b <+
        "<div class=\"field\"><label for=\"profile-display-name\"><span>Display name</span></label><input id=\"profile-display-name\" name=\"display_name\" value=\"\{display_name}\" maxlength=\"100\" autocomplete=\"name\" required></div>"
      b <+
        "<div class=\"field\"><label for=\"profile-time-zone\">Display time zone</label><select id=\"profile-time-zone\" name=\"time_zone\" aria-describedby=\"profile-time-zone-help profile-time-zone-preview\"><option value=\"\""
      if time_zone.is_empty() {
        b <+ " selected"
      }
      b <+ ">Follow device time zone</option>"
      if !time_zone.is_empty() &&
        !@identity.valid_display_time_zone(Some(time_zone)) {
        b <+
          "<option value=\"\{time_zone}\" selected>\{time_zone} (invalid)</option>"
      }
      for zone in @identity.display_time_zones() {
        b <+ "<option value=\"\{zone}\""
        if zone == time_zone {
          b <+ " selected"
        }
        b <+ ">\{zone}</option>"
      }
      b <+
        "</select><p id=\"profile-time-zone-help\" class=\"muted\">Follow each device’s time zone, or choose one to use across devices. Times use UTC when local display is unavailable.</p><p id=\"profile-time-zone-preview\" class=\"muted\" role=\"status\" aria-live=\"polite\" data-time-zone-preview></p></div>"
      b <+ "<div class=\"field\"><span>Email</span>"
      match profile.email {
        Some(email) => b <+ "<p class=\"path\">\{email}</p>"
        None => b <+ "<p class=\"muted\">No email on file.</p>"
      }
      b <+
        "</div><div class=\"form-actions\"><button type=\"submit\">Save profile</button></div></form></section>"
    }),
    current_user=Some(user),
    navigation=@web_ui.AccountNavigation("profile"),
    body_class="form-page",
  )
}
