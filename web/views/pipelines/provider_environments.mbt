///|
fn environment_form_values(
  value : @environment.Definition,
) -> Map[String, String] {
  {
    "name": value.name,
    "selector": value.selector,
    "architecture": value.architecture,
    "image": value.image,
    "labels": value.labels.join(","),
  }
}

///|
fn render_environment_form(
  control : @runtime.ProviderControl,
  csrf : String,
  id : String,
  values : Map[String, String],
) -> @moonback.Html {
  let prefix = "environment_" + id
  let legend = if id == "new" {
    "Add Linux environment"
  } else {
    "Edit " + values.get("name").unwrap_or("environment")
  }
  let caption = if id == "new" { "Add environment" } else { "Save environment" }
  Html(b => {
    b <+
      "<form class=\"form-stack environment-form\" method=\"post\" action=\"/-/admin/pipelines/providers/\{control.snapshot.id}/environments\" aria-labelledby=\"\{prefix}_legend\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"revision\" value=\"\{control.snapshot.config_revision}\"><input type=\"hidden\" name=\"environment_action\" value=\"save\"><input type=\"hidden\" name=\"profile_id\" value=\"\{id}\"><fieldset><legend id=\"\{prefix}_legend\">\{legend}</legend><p class=\"muted\">All fields are required except additional labels.</p>"
    b <+
      "<div class=\"field\"><label for=\"\{prefix}_name\">Name</label><small class=\"muted\" id=\"\{prefix}_name_help\">Also available as a runner label. Use lowercase letters, digits, dots and hyphens.</small><input id=\"\{prefix}_name\" name=\"name\" value=\"\{values.get("name").unwrap_or("")}\" maxlength=\"64\" pattern=\"[a-z0-9][a-z0-9.-]{0,63}\" required aria-describedby=\"\{prefix}_name_help\" autocorrect=\"off\" autocapitalize=\"none\" spellcheck=\"false\"></div>"
    b <+
      "<div class=\"field\"><label for=\"\{prefix}_selector\">Distribution</label><select id=\"\{prefix}_selector\" name=\"selector\" required>"
    for
      (selector, title) in [
        ("debian-12", "Debian 12"),
        ("ubuntu-22.04", "Ubuntu 22.04"),
        ("ubuntu-24.04", "Ubuntu 24.04"),
      ] {
      b <+ "<option value=\"\{selector}\""
      if values.get("selector").unwrap_or("debian-12") == selector {
        b <+ " selected"
      }
      b <+ ">\{title}</option>"
    }
    b <+
      "</select></div><fieldset class=\"environment-architecture\"><legend>Architecture</legend>"
    for (architecture, title) in [("x64", "x64"), ("arm64", "ARM64")] {
      b <+
        "<div class=\"environment-choice\"><input type=\"radio\" id=\"\{prefix}_\{architecture}\" name=\"architecture\" value=\"\{architecture}\" required"
      if values.get("architecture").unwrap_or("x64") == architecture {
        b <+ " checked"
      }
      b <+ "><label for=\"\{prefix}_\{architecture}\">\{title}</label></div>"
    }
    b <+
      "</fieldset><div class=\"field\"><label for=\"\{prefix}_image\">Runner image</label><small class=\"muted\" id=\"\{prefix}_image_help\">Use an image ending in @sha256: followed by its full digest. The worker verifies the distribution and architecture before accepting jobs.</small><input id=\"\{prefix}_image\" name=\"image\" value=\"\{values.get("image").unwrap_or("")}\" maxlength=\"256\" required aria-describedby=\"\{prefix}_image_help\" autocorrect=\"off\" autocapitalize=\"none\" spellcheck=\"false\"></div>"
    b <+
      "<div class=\"field\"><label for=\"\{prefix}_labels\">Additional labels (optional)</label><small class=\"muted\" id=\"\{prefix}_labels_help\">Comma separated. The name, distribution and architecture are included automatically.</small><input id=\"\{prefix}_labels\" name=\"labels\" value=\"\{values.get("labels").unwrap_or("")}\" maxlength=\"1039\" aria-describedby=\"\{prefix}_labels_help\" autocorrect=\"off\" autocapitalize=\"none\" spellcheck=\"false\"></div></fieldset><button type=\"submit\">"
    b <+ "\{caption}"
    b <+ "</button></form>"
  })
}

///|
fn render_provider_environments(
  control : @runtime.ProviderControl,
  csrf : String,
  submitted : Map[String, String],
  target : String,
  error : String?,
) -> @moonback.Html {
  if !control.linux_environments {
    return Html(_ => ())
  }
  let profiles = control.snapshot.environments.unwrap_or([])
  Html(b => {
    b <+
      "<section class=\"provider-environments\" id=\"linux-environments\"><h2>Linux environments</h2><p class=\"muted\">Choose an environment with runs-on. All environments share this provider's workers and task limits, and must use the same architecture. Running tasks keep their selected image.</p>"
    if error is Some(message) {
      b <+
        "<p class=\"flash-error\" role=\"alert\" tabindex=\"-1\" autofocus>\{message}</p>"
    }
    if control.environment_protocol != 1 {
      b <+
        "<p class=\"settings-notice\">Connect an updated moonhub-runner to configure Linux environments. Tasks continue to use the configured runner image.</p>"
    } else {
      if profiles.is_empty() {
        b <+
          "<p>No named environments. Tasks use the configured runner image.</p>"
      } else {
        b <+ "<ul class=\"mr-list provider-environment-list\">"
        for profile in profiles {
          let value = profile.environment
          b <+
            "<li data-environment=\"\{value.name}\"><div class=\"provider-environment-title\"><strong>\{value.name}</strong>"
          if profile.is_default {
            b <+ "<span class=\"muted\">Default</span>"
          }
          b <+
            "</div><p class=\"muted\">\{value.selector} · \{value.architecture}</p><p class=\"environment-image\"><code>\{value.image}</code></p><details class=\"secondary-details\""
          if error is Some(_) && target == profile.id {
            b <+ " open"
          }
          b <+
            "><summary>Edit \{value.name}</summary>\{render_environment_form(control, csrf, profile.id, if target == profile.id && error is Some(_) { submitted } else { environment_form_values(value) })}</details>"
          if !profile.is_default || profiles.length() == 1 {
            b <+
              "<form method=\"post\" action=\"/-/admin/pipelines/providers/\{control.snapshot.id}/environments\" class=\"environment-remove\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"revision\" value=\"\{control.snapshot.config_revision}\"><input type=\"hidden\" name=\"environment_action\" value=\"remove\"><input type=\"hidden\" name=\"profile_id\" value=\"\{profile.id}\"><button type=\"submit\" class=\"secondary-button\">Remove \{value.name}</button></form>"
          }
          b <+ "</li>"
        }
        b <+
          "</ul><form class=\"form-stack environment-default\" method=\"post\" action=\"/-/admin/pipelines/providers/\{control.snapshot.id}/environments\" aria-labelledby=\"default-environment-legend\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"revision\" value=\"\{control.snapshot.config_revision}\"><input type=\"hidden\" name=\"environment_action\" value=\"default\"><fieldset><legend id=\"default-environment-legend\">Default for generic Linux jobs</legend><p class=\"muted\">Jobs without an environment label use this image. Reruns retain their original image.</p>"
        for profile in profiles {
          b <+
            "<div class=\"environment-choice\"><input type=\"radio\" id=\"default_environment_\{profile.id}\" name=\"profile_id\" value=\"\{profile.id}\" required"
          if profile.is_default {
            b <+ " checked"
          }
          b <+
            "><label for=\"default_environment_\{profile.id}\">\{profile.environment.name}</label></div>"
        }
        b <+
          "</fieldset><button type=\"submit\">Save default</button></form><p class=\"muted\">Choose another default before removing the current default. Removing the last environment returns new jobs to the provider's runner image; saved jobs wait until their pinned image is available.</p>"
      }
      if profiles.length() < 8 {
        b <+ "<details class=\"secondary-details environment-add\""
        if profiles.is_empty() || (target == "new" && error is Some(_)) {
          b <+ " open"
        }
        b <+
          "><summary>Add Linux environment</summary>\{render_environment_form(control, csrf, "new", if target == "new" && error is Some(_) { submitted } else { { "architecture": profiles.get(0).map(profile => profile.environment.architecture).unwrap_or("x64") } })}</details>"
      }
    }
    b <+ "</section>"
  })
}

///|
fn updated_environment_values(
  control : @runtime.ProviderControl,
  form : Map[String, String],
) -> (Array[@environment.Definition], String) raise {
  let profiles = control.snapshot.environments.unwrap_or([])
  let target = form.get("profile_id").unwrap_or("new")
  let current = profiles.iter().find_first(profile => profile.id == target)
  let values = profiles.map(profile => profile.environment)
  let default_name = profiles
    .iter()
    .find_first(profile => profile.is_default)
    .map(profile => profile.environment.name)
    .unwrap_or("")
  match form.get("environment_action").unwrap_or("") {
    "default" => {
      guard current is Some(profile) else {
        raise @domain.BadRequest(message="Choose a saved environment.")
      }
      (values, profile.environment.name)
    }
    "remove" => {
      guard current is Some(profile) else {
        raise @domain.BadRequest(
          message="Environment changed. Reload before saving.",
        )
      }
      guard !profile.is_default || profiles.length() == 1 else {
        raise @domain.BadRequest(
          message="Choose another default before removing this environment.",
        )
      }
      (
        profiles
        .filter(profile => profile.id != target)
        .map(profile => profile.environment),
        if profiles.length() == 1 {
          ""
        } else {
          default_name
        },
      )
    }
    "save" => {
      let value : @environment.Definition = {
        name: form.get("name").unwrap_or("").trim().to_owned(),
        selector: form.get("selector").unwrap_or(""),
        architecture: form.get("architecture").unwrap_or(""),
        image: form.get("image").unwrap_or("").trim().to_owned(),
        labels: form
        .get("labels")
        .unwrap_or("")
        .split(",")
        .map(value => value.trim().to_owned())
        .filter(value => !value.is_empty())
        .collect(),
      }
      if target == "new" {
        (
          values + [value],
          if profiles.is_empty() {
            value.name
          } else {
            default_name
          },
        )
      } else {
        guard current is Some(profile) else {
          raise @domain.BadRequest(
            message="Environment changed. Reload before saving.",
          )
        }
        (
          profiles.map(profile => {
            if profile.id == target {
              value
            } else {
              profile.environment
            }
          }),
          if profile.is_default {
            value.name
          } else {
            default_name
          },
        )
      }
    }
    _ => raise @domain.BadRequest(message="Choose an environment action.")
  }
}
