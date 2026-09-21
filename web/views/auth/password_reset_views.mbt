///|
fn render_forgot_password(
  assets : Map[String, String],
  csrf : String,
  email : String,
  message : String?,
) -> @moonback.Html {
  @web_ui.layout(
    "Forgot password",
    assets,
    Html(b => {
      b <+ "<section class=\"auth-card\"><h1>Forgot password</h1>"
      if message is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"/-/forgot-password\">"
      b <+ "<input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\">"
      b <+
        "<label class=\"field\"><span>Email</span><input type=\"email\" name=\"email\" autocomplete=\"email\" maxlength=\"254\" value=\"\{email}\" required></label>"
      b <+
        #|<p class="form-actions"><button type="submit">Send reset code</button></p>
        #|</form>
        #|<p><a href="/-/reset-password">I have a reset code</a></p>
        #|<p><a href="/-/login">Back to sign in</a></p></section>
    }),
    body_class="auth-main",
  )
}

///|
fn render_reset_password(
  assets : Map[String, String],
  csrf : String,
  email : String,
  code : String,
  message : String?,
  requested : Bool,
) -> @moonback.Html {
  @web_ui.layout(
    "Reset password",
    assets,
    Html(b => {
      b <+ "<section class=\"auth-card\"><h1>Reset password</h1>"
      if requested {
        b <+
          "<p class=\"settings-notice\" role=\"status\">If an active account matches that email, a reset code will be sent. Codes expire after 30 minutes. Allow a minute before requesting another.</p>"
      }
      if message is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"/-/reset-password\">"
      b <+ "<input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\">"
      b <+
        "<label class=\"field\"><span>Email</span><input type=\"email\" name=\"email\" autocomplete=\"email\" maxlength=\"254\" value=\"\{email}\" required></label>"
      b <+
        "<label class=\"field\"><span>Reset code</span><input name=\"code\" autocomplete=\"one-time-code\" autocapitalize=\"none\" spellcheck=\"false\" maxlength=\"64\" value=\"\{code}\" required></label>"
      b <+
        #|<label class="field"><span>New password</span><input type="password" name="new_password" autocomplete="new-password" minlength="8" maxlength="72" required></label>
        #|<label class="field"><span>Confirm new password</span><input type="password" name="confirm_password" autocomplete="new-password" minlength="8" maxlength="72" required></label>
        #|<p class="form-actions"><button type="submit">Reset password</button></p>
        #|</form>
        #|<p><a href="/-/forgot-password">Request a new code</a></p>
        #|<p><a href="/-/login">Back to sign in</a></p></section>
    }),
    body_class="auth-main",
  )
}

///|
fn render_password_reset_success(
  assets : Map[String, String],
) -> @moonback.Html {
  @web_ui.layout(
    "Password reset",
    assets,
    Html(b => {
      b <+
        #|<section class="auth-card"><h1>Password reset</h1>
        #|<p class="settings-success" role="status">Your password has been reset. All previous sessions have been signed out.</p>
        #|<p><a class="button-link" href="/-/login">Sign in</a></p></section>
    }),
    body_class="auth-main",
  )
}
