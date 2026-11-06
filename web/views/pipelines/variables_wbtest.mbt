///|
async test "variable pages protect changes and display escaped readable values" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, bob) => {
    let base = "/alice/demo/settings/variables"
    let (empty, html) = @web_testkit.http_get_path_with_cookie(
      port, base, alice,
    )
    assert_eq(empty.code, 200)
    assert_eq(empty.headers.get("cache-control"), Some("no-store"))
    assert_true(html.contains("No repository variables"))
    assert_eq(
      @web_testkit.http_get_path_with_cookie(port, base, bob).0.code,
      404,
    )
    let (_, form) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/new",
      alice,
    )
    let csrf = @web_testkit.extract_attr(
      form, "name=\"csrf_token\"", "value=\"",
    )
    let fields = "name=region&value=%3Cscript%3E%26hello%3C%2Fscript%3E&version=0"
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, base, fields, alice).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base,
        fields + "&csrf_token=" + csrf,
        alice,
      ).0.code,
      303,
    )
    let (_, listing) = @web_testkit.http_get_path_with_cookie(port, base, alice)
    assert_true(listing.contains("REGION"))
    assert_true(listing.contains("&lt;script&gt;&amp;hello&lt;/script&gt;"))
    assert_false(listing.contains("<script>&hello</script>"))
    let (_, edit) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/REGION/edit",
      alice,
    )
    assert_true(edit.contains("&lt;script&gt;&amp;hello&lt;/script&gt;"))
    let version = @web_testkit.extract_attr(
      edit, "name=\"version\"", "value=\"",
    )
    let (stale, rejected) = @web_testkit.http_post_path_with_cookie(
      port,
      base + "/REGION",
      "value=%3Cnew%3E&version=0&csrf_token=" + csrf,
      alice,
    )
    assert_eq(stale.code, 400)
    assert_true(rejected.contains("&lt;new&gt;"))
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base + "/REGION",
        "value=&version=" + version + "&csrf_token=" + csrf,
        alice,
      ).0.code,
      303,
    )
    let (_, deletion) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/REGION/delete",
      alice,
    )
    assert_true(deletion.contains("Existing run snapshots"))
    let latest = @web_testkit.extract_attr(
      deletion, "name=\"version\"", "value=\"",
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base + "/REGION/delete",
        "version=" + latest + "&csrf_token=" + csrf,
        alice,
      ).0.code,
      303,
    )
    assert_true(
      @pipeline.list_variables(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        { owner: "alice", name: "demo", },
      ).is_empty(),
    )
  })
}

///|
async test "variable readers can view values but cannot manage them" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, bob) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    @pipeline.save_variable(
      pool,
      actor,
      { owner: "alice", name: "demo", },
      "REGION",
      "readable",
      0L,
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id,user_id,role) SELECT team_id,2,'member' FROM repository WHERE id=1",
        ),
      )
    })
    let base = "/alice/demo/settings/variables"
    let (response, html) = @web_testkit.http_get_path_with_cookie(
      port, base, bob,
    )
    assert_eq(response.code, 200)
    assert_true(html.contains("readable"))
    assert_false(html.contains("Add variable"))
    assert_false(html.contains("Edit variable"))
    assert_eq(
      @web_testkit.http_get_path_with_cookie(port, base + "/new", bob).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_get_path_with_cookie(port, base + "/REGION/edit", bob).0.code,
      403,
    )
    let (_, form) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/new",
      alice,
    )
    let csrf = @web_testkit.extract_attr(
      form, "name=\"csrf_token\"", "value=\"",
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base,
        "name=OTHER&value=no&version=0&csrf_token=" + csrf,
        bob,
      ).0.code,
      403,
    )
  })
}

///|
async test "variable forms accept maximum URL-encoded UTF8 values and reject one byte over" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, _) => {
    let base = "/alice/demo/settings/variables"
    let (_, form) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/new",
      alice,
    )
    let csrf = @web_testkit.extract_attr(
      form, "name=\"csrf_token\"", "value=\"",
    )
    let value = "%E6%96%87".repeat(16384)
    let fields = "name=TEXT&value=" + value + "&version=0&csrf_token=" + csrf
    assert_true(fields.length() > 65536)
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, base, fields, alice).0.code,
      303,
    )
    let variables = @pipeline.list_variables(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      { owner: "alice", name: "demo", },
    )
    assert_eq(variables[0].value, "文".repeat(16384))
    let (_, edit) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/TEXT/edit",
      alice,
    )
    let version = @web_testkit.extract_attr(
      edit, "name=\"version\"", "value=\"",
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base + "/TEXT",
        "value=" + value + "x&version=" + version + "&csrf_token=" + csrf,
        alice,
      ).0.code,
      400,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port,
        base,
        "name=BIG&value=" + "x".repeat(163840) + "&version=0&csrf_token=" + csrf,
        alice,
      ).0.code,
      400,
    )
  })
}

///|
async test "variable browser mutations reject cross-site and unauthenticated submissions" {
  @web_testkit.with_repository_test_app((port, pool, _, alice, _) => {
    let base = "/alice/demo/settings/variables"
    assert_eq(@web_testkit.http_get_path(port, base).0.code, 303)
    let (_, form) = @web_testkit.http_get_path_with_cookie(
      port,
      base + "/new",
      alice,
    )
    let csrf = @web_testkit.extract_attr(
      form, "name=\"csrf_token\"", "value=\"",
    )
    let fields = "name=REGION&value=test&version=0&csrf_token=" + csrf
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let denied = client.post(base, fields, extra_headers={
      "Content-Type": "application/x-www-form-urlencoded",
      "Cookie": "\{alice.name}=\{alice.value}",
      "Sec-Fetch-Site": "cross-site",
    })
    assert_eq(denied.code, 403)
    ignore(client.read_all())
    let anonymous = client.post(base, fields, extra_headers={
      "Content-Type": "application/x-www-form-urlencoded",
    })
    assert_eq(anonymous.code, 303)
    ignore(client.read_all())
    assert_true(
      @pipeline.list_variables(
        pool,
        @identity.active_user_by_name(pool, "alice"),
        { owner: "alice", name: "demo", },
      ).is_empty(),
    )
  })
}
