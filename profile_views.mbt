///|
fn render_profile_settings(
  assets : Map[String, String],
  user : CurrentUser,
  profile : UserProfile,
  csrf : String,
  display_name : String,
  error : String?,
  saved : Bool,
) -> @moonback.Html {
  layout(
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
        "<form class=\"form-stack\" method=\"post\" action=\"/settings/profile\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\">"
      b <+
        "<div class=\"field\"><label for=\"profile-name-key\"><span>Username</span></label><input id=\"profile-name-key\" class=\"path\" value=\"\{profile.name_key}\" readonly aria-describedby=\"profile-name-key-note\"></div><p id=\"profile-name-key-note\" class=\"muted\">Usernames identify repository namespaces and cannot be changed.</p>"
      b <+
        "<div class=\"field\"><label for=\"profile-display-name\"><span>Display name</span></label><input id=\"profile-display-name\" name=\"display_name\" value=\"\{display_name}\" maxlength=\"100\" autocomplete=\"name\" required></div>"
      b <+ "<div class=\"field\"><span>Email</span>"
      match profile.email {
        Some(email) => b <+ "<p class=\"path\">\{email}</p>"
        None => b <+ "<p class=\"muted\">No email on file.</p>"
      }
      b <+
        "</div><div class=\"form-actions\"><button type=\"submit\">Save profile</button></div></form></section>"
    }),
    current_user=Some(user),
    navigation=AccountNavigation("profile"),
    body_class="form-page",
  )
}
