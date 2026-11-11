///|
let dispatch_form_workflow : String =
  #|name: Typed browser dispatch
  #|on:
  #|  workflow_dispatch:
  #|    inputs:
  #|      version:
  #|        description: 'Version <b>"label"</b>'
  #|        type: string
  #|        required: true
  #|        default: '0.0.1'
  #|      release: {type: boolean, default: true}
  #|      count: {type: number, default: 3}
  #|      channel: {type: choice, options: [stable, 'beta <preview>'], default: stable}
  #|      notes: {type: string, default: '<script>alert("default")</script>'}
  #|jobs:
  #|  build:
  #|    runs-on: self-hosted
  #|    steps:
  #|      - run: echo browser dispatch

///|
async fn with_dispatch_form_app(
  f : async (Int32, @database.Database, @http.Cookie, @http.Cookie) -> Unit,
) -> Unit {
  @web_testkit.with_repository_test_app((port, pool, root, alice, bob) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let dir = repo.git_dir(root)
    let typed = @test_support.workflow_commit(dir, dispatch_form_workflow)
    let plain = @test_support.workflow_commit(
      dir, @test_support.single_job_workflow,
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/plain", plain]))
    let entries = StringBuilder()
    for entry in [("build.yml", typed), ("plain.yml", plain)] {
      let (path, commit) = entry
      let blob = @gitops.merge_git(dir, [
          "rev-parse",
          commit + ":.github/workflows/build.yml",
        ])
        .trim()
        .to_owned()
      entries.write_string("100644 blob \{blob}\t\{path}\n")
    }
    let workflows = @gitops.merge_git(
        dir,
        ["mktree"],
        input=entries.to_string(),
      )
      .trim()
      .to_owned()
    let github = @gitops.merge_git(
        dir,
        ["mktree"],
        input="040000 tree \{workflows}\tworkflows\n",
      )
      .trim()
      .to_owned()
    let tree = @gitops.merge_git(
        dir,
        ["mktree"],
        input="040000 tree \{github}\t.github\n",
      )
      .trim()
      .to_owned()
    let commit = @gitops.merge_git(dir, [
        "commit-tree", tree, "-m", "Browser dispatch fixtures",
      ])
      .trim()
      .to_owned()
    ignore(
      @gitops.merge_git(dir, ["update-ref", "refs/heads/pipeline", commit]),
    )
    f(port, pool, alice, bob)
  })
}

///|
async test "browser selects PR-only jobs without changing workflow or branch" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let source = @test_support.single_job_workflow.replace_all(
      old="workflow_dispatch",
      new="pull_request",
    )
    let sha = @test_support.workflow_commit(repo.git_dir(root), source)
    let (_, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/pipelines/new?branch=pipeline", cookie,
    )
    assert_true(body.contains("<select name=\"job\">"))
    assert_true(body.contains("value=\"build\""))
    assert_false(body.contains("All workflow jobs"))
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let (response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/pipelines",
      "csrf_token=" +
      csrf +
      "&branch=pipeline&workflow=.github/workflows/build.yml&job=build",
      cookie,
    )
    assert_eq(response.code, 303)
    assert_eq(@gitops.branch_sha(repo.git_dir(root), "pipeline"), sha)
    let actor = @identity.active_user_by_name(pool, "alice")
    assert_eq(@pipeline.get_run(pool, actor, repo, 1L).workflow_source, source)
  })
}

///|
async test "browser dispatch GET reloads selected workflow schema and escapes defaults" {
  with_dispatch_form_app((port, _, cookie, _) => {
    let route = "/alice/demo/pipelines/new?branch=pipeline"
    let (response, body) = @web_testkit.http_get_path_with_cookie(
      port,
      route + "&workflow=.github/workflows/build.yml",
      cookie,
    )
    assert_eq(response.code, 200)
    assert_eq(response.headers.get("cache-control"), Some("no-store"))
    assert_true(
      body.contains("method=\"get\" action=\"/alice/demo/pipelines/new\""),
    )
    assert_true(
      body.contains("name=\"workflow\" value=\".github/workflows/build.yml\""),
    )
    assert_true(
      body.contains("name=\"input:version\" value=\"0.0.1\" required"),
    )
    assert_true(body.contains("Version &lt;b&gt;\"label\"&lt;/b&gt;"))
    assert_true(
      body.contains(
        "name=\"input:count\" value=\"3\" type=\"number\" step=\"any\"",
      ),
    )
    assert_true(
      body.contains("<option value=\"true\" selected=\"\">true</option>"),
    )
    assert_true(body.contains("value=\"beta &lt;preview&gt;\""))
    assert_true(
      body.contains(
        "value=\"&lt;script&gt;alert(&quot;default&quot;)&lt;/script&gt;\"",
      ),
    )
    assert_false(body.contains("<script>alert("))
    let (selected, plain) = @web_testkit.http_get_path_with_cookie(
      port,
      route + "&workflow=.github/workflows/plain.yml",
      cookie,
    )
    assert_eq(selected.code, 200)
    assert_true(
      plain.contains("value=\".github/workflows/plain.yml\" selected"),
    )
    assert_true(
      plain.contains("name=\"workflow\" value=\".github/workflows/plain.yml\""),
    )
    assert_false(plain.contains("name=\"input:"))
    let (branch, plain_branch) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/pipelines/new?branch=plain", cookie,
    )
    assert_eq(branch.code, 200)
    assert_true(plain_branch.contains("name=\"branch\" value=\"plain\""))
    assert_false(plain_branch.contains("name=\"input:"))
  })
}

///|
async test "browser dispatch creates typed inputs including explicit false and defaults" {
  with_dispatch_form_app((port, pool, cookie, _) => {
    let (_, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/pipelines/new?branch=pipeline", cookie,
    )
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let (response, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/pipelines",
      "csrf_token=" +
      csrf +
      "&branch=pipeline&workflow=.github/workflows/build.yml&input:version=1.2.3&input:release=false&input:count=2.5&input:channel=beta%20%3Cpreview%3E",
      cookie,
    )
    assert_eq(response.code, 303)
    assert_eq(response.headers.get("location"), Some("/alice/demo/pipelines/1"))
    let run = @pipeline.get_run(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      { owner: "alice", name: "demo", },
      1L,
    )
    let inputs = run.context.unwrap().inputs
    assert_eq(inputs.get("version"), Some(Json("1.2.3")))
    assert_eq(inputs.get("release"), Some(Json(false)))
    assert_eq(inputs.get("count"), Some(Json(2.5)))
    assert_eq(inputs.get("channel"), Some(Json("beta <preview>")))
    assert_eq(
      inputs.get("notes"),
      Some(Json("<script>alert(\"default\")</script>")),
    )
  })
}

///|
async test "browser dispatch validation errors retain escaped submitted values and workflow selection" {
  with_dispatch_form_app((port, pool, cookie, _) => {
    let (_, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/pipelines/new?branch=pipeline", cookie,
    )
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let fields = "csrf_token=" +
      csrf +
      "&branch=pipeline&workflow=.github/workflows/build.yml&input:version=%22%3E%3Cscript%3Ealert%281%29%3C%2Fscript%3E&input:release=false&input:count=2.5"
    for
      invalid in [
        "&input:channel=nightly%20%3Cscript%3E", "&input:channel=stable&input:unknown=%3Cscript%3E",
      ] {
      let (response, error) = @web_testkit.http_post_path_with_cookie(
        port,
        "/alice/demo/pipelines",
        fields + invalid,
        cookie,
      )
      assert_eq(response.code, 400)
      assert_eq(response.headers.get("cache-control"), Some("no-store"))
      assert_true(error.contains("role=\"alert\""))
      assert_true(
        error.contains("method=\"get\" action=\"/alice/demo/pipelines/new\""),
      )
      assert_true(
        error.contains(
          "name=\"workflow\" value=\".github/workflows/build.yml\"",
        ),
      )
      assert_true(
        error.contains(
          "name=\"input:version\" value=\"&quot;&gt;&lt;script&gt;alert(1)&lt;/script&gt;\"",
        ),
      )
      assert_true(
        error.contains("<option value=\"false\" selected=\"\">false</option>"),
      )
      assert_true(error.contains("name=\"input:count\" value=\"2.5\""))
      assert_false(error.contains("<script>alert(1)</script>"))
      if invalid.contains("nightly") {
        assert_true(
          error.contains(
            "<option value=\"nightly &lt;script&gt;\" selected=\"\">nightly &lt;script&gt; (invalid)</option>",
          ),
        )
      }
    }
    for
      invalid in [
        "input:version=", "input:release=neither", "input:count=not-a-number",
      ] {
      let (response, error) = @web_testkit.http_post_path_with_cookie(
        port,
        "/alice/demo/pipelines",
        "csrf_token=" +
        csrf +
        "&branch=pipeline&workflow=.github/workflows/build.yml&" +
        invalid,
        cookie,
      )
      assert_eq(response.code, 400)
      if invalid == "input:version=" {
        assert_true(
          error.contains("name=\"input:version\" value=\"\" required"),
        )
      } else if invalid == "input:release=neither" {
        assert_true(
          error.contains(
            "<option value=\"neither\" selected=\"\">neither (invalid)</option>",
          ),
        )
      } else {
        assert_true(
          error.contains(
            "name=\"input:count\" value=\"not-a-number\" type=\"text\" inputmode=\"decimal\" aria-invalid=\"true\"",
          ),
        )
      }
    }
    assert_true(
      @pipeline.list_runs(pool, @identity.active_user_by_name(pool, "alice"), {
        owner: "alice",
        name: "demo",
      }).is_empty(),
    )
  })
}

///|
async test "browser dispatch requires authentication repository permission and CSRF" {
  with_dispatch_form_app((port, pool, cookie, bob) => {
    let route = "/alice/demo/pipelines"
    let (anonymous, _) = @web_testkit.http_get_path(
      port,
      route + "/new?branch=pipeline",
    )
    assert_eq(anonymous.code, 303)
    let (denied, _) = @web_testkit.http_get_path_with_cookie(
      port,
      route + "/new?branch=pipeline",
      bob,
    )
    assert_eq(denied.code, 404)
    let (reader, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/public/pipelines/new", bob,
    )
    assert_eq(reader.code, 404)
    let (_, body) = @web_testkit.http_get_path_with_cookie(
      port,
      route + "/new?branch=pipeline",
      cookie,
    )
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let fields = "branch=pipeline&workflow=.github/workflows/build.yml&input:version=1.2.3"
    for
      token in [
        "",
        "&csrf_token=invalid",
        "&csrf_token=" +
        @web_context.form_csrf_token(cookie.value, "pipelines:settings"),
      ] {
      let (response, _) = @web_testkit.http_post_path_with_cookie(
        port,
        route,
        fields + token,
        cookie,
      )
      assert_eq(response.code, 403)
    }
    let (denied, _) = @web_testkit.http_post_path_with_cookie(
      port,
      route,
      fields + "&csrf_token=" + csrf,
      bob,
    )
    assert_eq(denied.code, 404)
    let (reader, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/public/pipelines",
      fields + "&csrf_token=" + csrf,
      bob,
    )
    assert_eq(reader.code, 404)
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let anonymous = client.post(route, fields, extra_headers={
      "Content-Type": "application/x-www-form-urlencoded",
    })
    assert_eq(anonymous.code, 303)
    ignore(client.read_all())
    let cross_site = client.post(route, fields + "&csrf_token=" + csrf, extra_headers={
      "Content-Type": "application/x-www-form-urlencoded",
      "Cookie": "\{cookie.name}=\{cookie.value}",
      "Sec-Fetch-Site": "cross-site",
    })
    assert_eq(cross_site.code, 403)
    ignore(client.read_all())
    assert_true(
      @pipeline.list_runs(pool, @identity.active_user_by_name(pool, "alice"), {
        owner: "alice",
        name: "demo",
      }).is_empty(),
    )
  })
}

///|
async test "browser dispatch accepts maximum UTF8 inputs after percent encoding" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let workflow = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on:\n  workflow_dispatch:\n    inputs:\n      payload: {required: true}",
    )
    ignore(@test_support.workflow_commit(repo.git_dir(root), workflow))
    let (_, body) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/pipelines/new?branch=pipeline", cookie,
    )
    let csrf = @web_testkit.extract_attr(
      body, "name=\"csrf_token\"", "value=\"",
    )
    let overhead = @utf8.encode(Json({ "payload": "" }).stringify()).length()
    let remaining = 65535 - overhead
    let value = "文".repeat(remaining / 3) + "a".repeat(remaining % 3)
    assert_eq(
      @utf8.encode(Json({ "payload": value }).stringify()).length(),
      65535,
    )
    let fields = "csrf_token=" +
      csrf +
      "&branch=pipeline&workflow=.github/workflows/build.yml&input:payload=" +
      @web_context.url_escape_path(value)
    assert_true(@utf8.encode(fields).length() > 196000)
    let (created, _) = @web_testkit.http_post_path_with_cookie(
      port, "/alice/demo/pipelines", fields, cookie,
    )
    assert_eq(created.code, 303)
    let run = @pipeline.get_run(pool, actor, repo, 1L)
    assert_eq(run.context.unwrap().inputs.get("payload"), Some(Json(value)))
    let (invalid, error) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/pipelines",
      fields + "x",
      cookie,
    )
    assert_eq(invalid.code, 400)
    assert_true(error.contains("65535"))
    let (oversized, error) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/pipelines",
      fields + "x".repeat(212993 - fields.length()),
      cookie,
    )
    assert_eq(oversized.code, 400)
    assert_true(error.contains("form is too large"))
    assert_eq(@pipeline.list_runs(pool, actor, repo).length(), 1)
  })
}
