///|
async test "managed provider HTTP registration and runtime settings enforce separate credentials and revisions" {
  @web_testkit.with_ssh_settings_app((port, pool, alice, _, cookie) => {
    let coordinator = @pipeline.Coordinator::new(pool)
    let admin = @identity.active_user_by_name(pool, "admin")
    let registration = "a".repeat(64)
    let token = "b".repeat(64)
    let worker = "c".repeat(64)
    let provider = coordinator.create_provider(
      admin,
      "runtime",
      registration,
      ["self-hosted", "linux"],
      [],
    )
    let request : @protocol.RegisterProviderRequest = {
      version: 1,
      name: "runtime",
      mode: "docker",
      provider_token: token,
      schema: [
        {
          name: "runner_image",
          title: "Runner image",
          kind: "text",
          required: true,
          minimum: 0,
          maximum: 0,
          choices: [],
          help: "New tasks only.",
        },
      ],
      defaults: { "runner_image": "runner:v1" },
    }
    let body = ToJson::to_json(request).stringify()
    assert_eq(post_json(port, "/providers/register", body).0, 401)
    assert_eq(
      post_json(
        port,
        "/providers/register",
        body,
        cookie=cookie.name + "=" + cookie.value,
      ).0,
      401,
    )
    assert_eq(
      post_json(port, "/providers/register", body, token=registration).0,
      200,
    )
    assert_eq(
      post_json(port, "/providers/register", body, token=registration).0,
      200,
    )
    let sync : @protocol.ProviderSyncRequest = {
      version: 1,
      controller_id: "controller",
      observed_revision: "1",
      applied_revision: "1",
      status: "applied",
    }
    assert_eq(
      post_json(
        port,
        "/providers/sync",
        ToJson::to_json(sync).stringify(),
        token=registration,
      ).0,
      401,
    )
    assert_eq(
      post_json(
        port,
        "/providers/sync",
        ToJson::to_json(sync).stringify(),
        token~,
      ).0,
      200,
    )
    let w : @protocol.WorkerRegistration = {
      version: 1,
      key: "worker-one",
      token: worker,
    }
    assert_eq(
      post_json(
        port,
        "/workers/register",
        ToJson::to_json(w).stringify(),
        token~,
      ).0,
      200,
    )
    assert_eq(
      post_json(
        port,
        "/workers/register",
        ToJson::to_json({ ..w, key: "stolen", }).stringify(),
        token=worker,
      ).0,
      401,
    )
    let route = "/-/admin/pipelines/providers/" +
      provider.id.to_string() +
      "/configuration"
    let (page, html) = @web_testkit.http_get_path_with_cookie(
      port, route, cookie,
    )
    assert_eq(page.code, 200)
    assert_eq(page.headers.get("cache-control"), Some("no-store"))
    assert_true(html.contains("name=\"config_runner_image\""))
    assert_true(!html.contains(token) && !html.contains(worker))
    assert_eq(
      @web_testkit.http_get_path_with_cookie(port, route, alice).0.code,
      403,
    )
    let csrf = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(
        port, route, "revision=1&config_runner_image=runner:v2", cookie,
      ).0.code,
      403,
    )
    let fields = "csrf_token=" +
      csrf +
      "&revision=1&config_runner_image=runner:v2"
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, route, fields, alice).0.code,
      403,
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, route, fields, cookie).0.code,
      303,
    )
    assert_eq(
      coordinator.provider_control(admin, provider.id).snapshot.config_revision,
      "2",
    )
    assert_eq(
      @web_testkit.http_post_path_with_cookie(port, route, fields, cookie).0.code,
      409,
    )
    assert_eq(
      coordinator.provider_control(admin, provider.id).snapshot.config.get(
        "runner_image",
      ),
      Some("runner:v2"),
    )
    let invalid = "csrf_token=" +
      csrf +
      "&revision=2&config_runner_image=%3Cbad%3E%0A"
    let (response, error) = @web_testkit.http_post_path_with_cookie(
      port, route, invalid, cookie,
    )
    assert_eq(response.code, 400)
    assert_true(error.contains("&lt;bad&gt;"))
    assert_true(!error.contains("<bad>"))
    let ready : @protocol.WorkerSyncRequest = {
      version: 1,
      state: "ready",
      applied_revision: "2",
    }
    assert_eq(
      post_json(
        port,
        "/workers/sync",
        ToJson::to_json(ready).stringify(),
        token=worker,
      ).0,
      200,
    )
    assert_eq(
      post_json(
        port,
        "/providers/sync",
        ToJson::to_json(sync).stringify(),
        token=worker,
      ).0,
      401,
    )
    coordinator.revoke_provider(admin, provider.id)
    assert_eq(
      post_json(
        port,
        "/workers/sync",
        ToJson::to_json(ready).stringify(),
        token=worker,
      ).0,
      401,
    )
    assert_eq(
      @web_testkit.http_get_path_with_cookie(port, route, cookie).0.code,
      404,
    )
  })
}

///|
async test "worker display separates terminal history without hiding unfinished tasks" {
  let ready : @protocol.WorkerView = {
    id: "1",
    key: "ready-worker",
    state: "ready",
    draining: false,
    applied_revision: "3",
    last_seen_ms: "1",
    idle_since_ms: "1",
    active_attempts: 0,
  }
  let stopped = {
    ..ready,
    id: "2",
    key: "stopped-worker",
    state: "drained",
    draining: true,
  }
  let failed = {
    ..ready,
    id: "3",
    key: "<failed-worker>",
    state: "failed",
    draining: true,
  }
  let unfinished = {
    ..failed,
    id: "4",
    key: "unfinished-worker",
    active_attempts: 1,
  }
  let draining = { ..ready, id: "5", key: "draining-worker", draining: true, }
  let app = @moonback.App(
    Module(ctx => {
      ctx.get("/empty", async fn(_, res) {
        res.send_html(render_provider_workers([]))
      })
      ctx.get("/history", async fn(_, res) {
        res.send_html(render_provider_workers([stopped, failed]))
      })
      ctx.get("/mixed", async fn(_, res) {
        res.send_html(
          render_provider_workers([ready, stopped, failed, unfinished, draining]),
        )
      })
    }),
  )
  defer app.close()
  @async.with_task_group(group => {
    let listener = @moonback.listen(port=0)
    let serving = group.spawn(() => app.serve(listener))
    defer serving.cancel()
    let port = listener.addr.port()
    let (_, empty) = @web_testkit.http_get_path(port, "/empty")
    assert_true(empty.contains("Current workers (0)"))
    assert_true(empty.contains("No current workers."))
    assert_true(empty.contains("Worker history (0)"))
    assert_true(empty.contains("No worker history."))
    let (_, history) = @web_testkit.http_get_path(port, "/history")
    assert_true(history.contains("Current workers (0)"))
    assert_true(history.contains("Worker history (2)"))
    assert_false(history.contains(" · draining"))
    assert_true(history.contains("Stopped · configuration 3"))
    assert_true(history.contains("Failed · configuration 3"))
    assert_true(history.contains("&lt;failed-worker&gt;"))
    assert_false(history.contains("<failed-worker>"))
    assert_true(
      history.contains(
        "<details class=\"secondary-details provider-worker-history\"><summary>",
      ),
    )
    let (_, mixed) = @web_testkit.http_get_path(port, "/mixed")
    assert_true(mixed.contains("Current workers (3)"))
    assert_true(mixed.contains("Worker history (2)"))
    assert_true(
      mixed.contains(
        "<strong>unfinished-worker</strong><p class=\"muted\">failed · configuration 3 · active tasks 1</p>",
      ),
    )
    assert_true(
      mixed.contains(
        "<strong>draining-worker</strong><p class=\"muted\">ready · configuration 3 · active tasks 0 · draining</p>",
      ),
    )
    assert_false(mixed.contains("No current workers."))
    assert_false(mixed.contains("No worker history."))
  })
}
