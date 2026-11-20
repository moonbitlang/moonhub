///|
async test "environment forms preserve authorization revisions defaults and invalid input" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, cookie) => {
    let c = @pipeline.Coordinator::new(pool)
    let admin = @identity.active_user_by_name(pool, "admin")
    let provider = c.create_provider(
      admin,
      "environments",
      "a".repeat(64),
      ["self-hosted", "linux"],
      [],
    )
    ignore(
      c.register_runner("a".repeat(64), {
        version: 1,
        name: "environments",
        mode: "docker",
        provider_token: "b".repeat(64),
        schema: [
          {
            name: "runner_image",
            title: "Runner image",
            kind: "text",
            required: true,
            choices: [],
            minimum: 0,
            maximum: 0,
            help: "Default task image.",
          },
        ],
        defaults: { "runner_image": "runner:legacy" },
      }),
    )
    let sync : @protocol.ProviderSyncRequest = {
      environment_protocol: Some(1),
      version: 1,
      controller_id: "controller",
      observed_revision: "1",
      applied_revision: "1",
      status: "applied",
      schema: None,
      defaults: None,
    }
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        "/providers/sync",
        ToJson::to_json(sync).stringify(),
        token="b".repeat(64),
      ).0,
      200,
    )
    let base = "/-/admin/pipelines/providers/" + provider.id.to_string()
    let (page, html) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/configuration",
      cookie,
    )
    assert_eq(page.code, 200)
    assert_true(html.contains("Linux environments"))
    assert_true(html.contains("<legend>Architecture</legend>"))
    let csrf = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    let route = base + "/environments"
    let fields = "csrf_token=" +
      csrf +
      "&environment_action=save&profile_id=new&revision=1&name=debian&selector=debian-12&architecture=x64&image=registry.example/runner%40sha256%3A" +
      "a".repeat(64)
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, route, fields, alice).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        route,
        fields.replace_all(old="csrf_token=", new="ignored="),
        cookie,
      ).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, route, fields, cookie).0.code,
      303,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, route, fields, cookie).0.code,
      409,
    )
    let first = c.provider_control(admin, provider.id).snapshot.environments.unwrap()[0]
    assert_true(first.is_default)
    let invalid = fields
      .replace_all(old="revision=1", new="revision=2")
      .replace_all(old="name=debian", new="name=%3Cscript%3E")
    let (response, error) = @web_testkit.http_post_path_with_cookie(
      port, route, invalid, cookie,
    )
    assert_eq(response.code, 400)
    assert_true(error.contains("value=\"&lt;script&gt;\""))
    assert_false(error.contains("value=\"<script>\""))
    assert_true(error.contains("role=\"alert\""))
    let ubuntu = fields
      .replace_all(old="revision=1", new="revision=2")
      .replace_all(old="name=debian", new="name=ubuntu")
      .replace_all(old="selector=debian-12", new="selector=ubuntu-24.04")
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, route, ubuntu, cookie).0.code,
      303,
    )
    let profiles = c.provider_control(admin, provider.id).snapshot.environments.unwrap()
    let debian_id = profiles
      .iter()
      .find_first(p => p.environment.name == "debian")
      .unwrap().id
    let ubuntu_id = profiles
      .iter()
      .find_first(p => p.environment.name == "ubuntu")
      .unwrap().id
    let prefix = "csrf_token=" + csrf + "&revision=3&profile_id="
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        route,
        prefix + debian_id + "&environment_action=remove",
        cookie,
      ).0.code,
      400,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        route,
        prefix + ubuntu_id + "&environment_action=default",
        cookie,
      ).0.code,
      303,
    )
    assert_true(
      c.provider_control(admin, provider.id).snapshot.environments
      .unwrap()
      .any(p => p.environment.name == "ubuntu" && p.is_default),
    )
    let (saved, rendered) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/configuration",
      cookie,
    )
    assert_eq(saved.code, 200)
    assert_true(
      rendered.contains(
        "<strong>ubuntu</strong><span class=\"muted\">Default</span>",
      ),
    )
    assert_true(rendered.contains("All environments share this provider"))
    assert_eq(saved.headers.get("cache-control"), Some("no-store"))
  })
}
