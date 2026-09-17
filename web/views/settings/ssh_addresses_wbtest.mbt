///|
async test "SSH site settings require admin access and session-bound CSRF" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, admin) => {
    let (anonymous, _) = @web_testkit.http_get_path(
      port, "/-/admin/settings/ssh",
    )
    assert_eq(anonymous.code, 303)
    let (denied, _) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/settings/ssh", alice,
    )
    assert_eq(denied.code, 403)
    let (page, body) = @web_testkit.http_get_path_with_cookie(
      port, "/-/admin/settings/ssh", admin,
    )
    assert_eq(page.code, 200)
    assert_true(page.headers.get("cache-control") is Some("no-store"))
    let token = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let wrong_scope = @web_testkit.settings_form_token(port, admin)
    for csrf in ["", "forged", wrong_scope] {
      let (rejected, _) = @web_testkit.http_post_path_with_cookie(
        port,
        "/-/admin/settings/ssh",
        "csrf_token=\{csrf}&host=git.example.com&port=12222",
        admin,
      )
      assert_eq(rejected.code, 403)
    }
    let (forbidden, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/admin/settings/ssh",
      "csrf_token=\{token}&host=git.example.com&port=12222",
      alice,
    )
    assert_eq(forbidden.code, 403)
    assert_true(
      @repository.effective_ssh_endpoint(
        pool, @repository.no_ssh_address_config,
      )
      is None,
    )
    let (invalid, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/admin/settings/ssh",
      "csrf_token=\{token}&host=0.0.0.0&port=22",
      admin,
    )
    assert_eq(invalid.code, 400)
    let (saved, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/-/admin/settings/ssh",
      "csrf_token=\{token}&host=Git.Example.com&port=12222",
      admin,
    )
    assert_eq(saved.code, 303)
    assert_eq(
      @repository.effective_ssh_endpoint(
        pool, @repository.no_ssh_address_config,
      )
      .unwrap()
      .authority(),
      "git.example.com:12222",
    )
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let cross_site = client.post(
      "/-/admin/settings/ssh",
      "csrf_token=\{token}&host=other.example&port=22",
      extra_headers={
        "Cookie": "\{admin.name}=\{admin.value}",
        "Sec-Fetch-Site": "cross-site",
        "Content-Type": "application/x-www-form-urlencoded",
      },
    )
    client.skip_response_body()
    assert_eq(cross_site.code, 403)
  })
}

///|
async test "clone URLs use live site configuration and never request host headers" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, _) => {
    let (_, initial) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", alice,
    )
    assert_true(initial.contains("SSH clone address is not configured."))
    assert_true(!initial.contains("data-clone-url"))
    let admin = @identity.active_user_by_name(pool, "admin")
    @repository.save_ssh_endpoint(
      pool, admin, @repository.no_ssh_address_config, "git.example.com", "12222",
    )
    let (_, configured) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo", alice,
    )
    assert_true(
      configured.contains("ssh://git@git.example.com:12222/alice/demo.git"),
    )
    assert_true(configured.contains("data-clone-copy"))
    assert_true(!configured.contains("aria-label=\"Site settings\""))
    @repository.save_ssh_endpoint(
      pool, admin, @repository.no_ssh_address_config, "new.example.com", "22",
    )
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client.get("/alice/demo", extra_headers={
      "Cookie": "\{alice.name}=\{alice.value}",
      "Host": "forged.example",
      "X-Forwarded-Host": "forged.example",
    })
    let body = client.read_all().text()
    assert_eq(response.code, 200)
    assert_true(body.contains("ssh://git@new.example.com:22/alice/demo.git"))
    assert_true(!body.contains("forged.example"))
  })
}

///|
async test "deployment SSH endpoint override is visible readonly and authoritative" {
  @web_testkit.with_ssh_settings_app(
    (port, pool, alice, _, admin_cookie) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      @repository.save_ssh_endpoint(
        pool, admin, @repository.no_ssh_address_config, "saved.example", "22",
      )
      assert_eq(
        @repository.effective_ssh_endpoint(
          pool, @web_testkit.test_ssh_addresses,
        )
        .unwrap()
        .authority(),
        "git.example.com:12222",
      )
      let (_, body) = @web_testkit.http_get_path_with_cookie(
        port, "/-/admin/settings/ssh", admin_cookie,
      )
      assert_true(body.contains("Managed by deployment configuration"))
      assert_true(body.contains("class=\"ssh-address-fields\" disabled"))
      assert_true(body.contains("ssh://git@ssh:2222"))
      let token = @web_testkit.extract_attr(
        body, "name=\"csrf_token\"", "value=\"",
      )
      let (locked, _) = @web_testkit.http_post_path_with_cookie(
        port,
        "/-/admin/settings/ssh",
        "csrf_token=\{token}&host=other.example&port=22",
        admin_cookie,
      )
      assert_eq(locked.code, 403)
      assert_eq(
        @repository.effective_ssh_endpoint(
          pool, @repository.no_ssh_address_config,
        )
        .unwrap()
        .authority(),
        "saved.example:22",
      )
      let (_, repo) = @web_testkit.http_get_path_with_cookie(
        port, "/alice/demo", alice,
      )
      assert_true(
        repo.contains("ssh://git@git.example.com:12222/alice/demo.git"),
      )
      assert_true(!repo.contains("ssh://git@ssh:2222"))
    },
    addresses=@web_testkit.test_ssh_addresses,
  )
}
