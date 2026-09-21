///|
fn render_login(
  asset_path_map : Map[String, String],
  message : String?,
  identifier? : String = "",
) -> @moonback.Html {
  @web_ui.layout(
    "Sign in",
    asset_path_map,
    Html(b => {
      b <+ "<section class=\"auth-card\"><h1>Sign in</h1>"
      match message {
        Some(message) =>
          b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
        None => ()
      }
      b <+
        #|<form class="form-stack" method="post" action="/-/login">
      b <+
        "<label class=\"field\"><span>Username or email</span><input name=\"name_key\" autocomplete=\"username\" autocapitalize=\"none\" spellcheck=\"false\" value=\"\{identifier}\" required></label>"
      b <+
        #|<label class="field"><span>Password</span><input type="password" name="password" autocomplete="current-password" required></label>
        #|<p class="form-actions"><button type="submit">Sign in</button></p>
        #|</form>
        #|<p><a href="/-/forgot-password">Forgot password?</a></p></section>
    }),
    body_class="auth-main",
  )
}

///|
fn render_change_password(
  asset_path_map : Map[String, String],
  user : @domain.CurrentUser,
  message : String?,
  required : Bool,
) -> @moonback.Html {
  @web_ui.layout(
    "Change password",
    asset_path_map,
    Html(b => {
      b <+ "<section class=\"auth-card\"><h1>Change password</h1>"
      b <+
        "<p class=\"muted\">Signed in as \{user.display_name} (\{user.name_key}).</p>"
      if required {
        b <+ "<p class=\"muted\">You must set a password before continuing.</p>"
      }
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      b <+
        #|<form class="form-stack" method="post" action="/-/change-password">
        #|<label class="field"><span>New password</span><input type="password" name="new_password" autocomplete="new-password" minlength="8" required></label>
        #|<label class="field"><span>Confirm new password</span><input type="password" name="confirm_password" autocomplete="new-password" minlength="8" required></label>
        #|<p class="form-actions"><button type="submit">Change password</button></p>
        #|</form></section>
    }),
    body_class="auth-main",
    current_user=Some(user),
    navigation=@web_ui.AccountNavigation("password"),
  )
}

///|
fn render_invitation_password(
  asset_path_map : Map[String, String],
  invitation : @identity.InvitationSession,
  message : String?,
) -> @moonback.Html {
  @web_ui.layout(
    "Set password",
    asset_path_map,
    Html(b => {
      b <+ "<section class=\"auth-card\"><h1>Set password</h1>"
      b <+
        "<p class=\"muted\">Signed in as \{invitation.display_name} (\{invitation.name_key}).</p>"
      b <+ "<p class=\"muted\">Set a password to activate this account.</p>"
      match message {
        Some(message) => b <+ "<p class=\"flash-error\">\{message}</p>"
        None => ()
      }
      b <+
        #|<form class="form-stack" method="post" action="/-/change-password">
        #|<label class="field"><span>New password</span><input type="password" name="new_password" autocomplete="new-password" minlength="8" required></label>
        #|<label class="field"><span>Confirm new password</span><input type="password" name="confirm_password" autocomplete="new-password" minlength="8" required></label>
        #|<p class="form-actions"><button type="submit">Set password</button></p>
        #|</form></section>
    }),
    body_class="auth-main",
  )
}
