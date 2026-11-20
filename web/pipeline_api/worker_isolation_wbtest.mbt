///|
async test "isolation HTTP acknowledgement requires the live outside controller and exact revision" {
  @web_testkit.with_ssh_settings_app((port, pool, cookie, _, _) => {
    let c = @pipeline.Coordinator::new(pool)
    ignore(
      c.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "ci-http",
        "a".repeat(64),
        ["self-hosted", "linux"],
        [],
      ),
    )
    ignore(
      c.register_runner("a".repeat(64), {
        version: 1,
        name: "ci-http",
        mode: "asg",
        provider_token: "b".repeat(64),
        schema: [
          {
            name: "execution_mode",
            title: "Execution",
            kind: "choice",
            required: true,
            choices: ["linux-ci"],
            minimum: 0,
            maximum: 0,
            help: "Single-use.",
          },
        ],
        defaults: { "execution_mode": "linux-ci" },
      }),
    )
    ignore(
      c.sync_provider("b".repeat(64), {
        environment_protocol: None,
        version: 1,
        controller_id: "manager",
        observed_revision: "1",
        applied_revision: "1",
        status: "applied",
        schema: None,
        defaults: None,
      }),
    )
    let worker = c.register_worker("b".repeat(64), {
      version: 1,
      key: "i-http",
      token: "c".repeat(64),
    })
    let path = "/workers/" + worker.id + "/isolation"
    let body : Json = {
      "version": 1,
      "controller_id": "manager",
      "revision": "1",
    }
    assert_eq(
      @web_testkit.runner_post_json(port, path, body.stringify()).0,
      401,
    )
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        path,
        body.stringify(),
        cookie=cookie.name + "=" + cookie.value,
      ).0,
      401,
    )
    for token in ["a".repeat(64), "c".repeat(64), "d".repeat(64)] {
      assert_eq(
        @web_testkit.runner_post_json(port, path, body.stringify(), token~).0,
        401,
      )
    }
    for
      bad in [
        ({ "version": 2, "controller_id": "manager", "revision": "1" } : Json),
        { "version": 1, "controller_id": "manager" },
        {
          "version": 1,
          "controller_id": "manager",
          "revision": "1",
          "extra": true,
        },
      ] {
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          path,
          bad.stringify(),
          token="b".repeat(64),
        ).0,
        400,
      )
    }
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        path,
        ({ "version": 1, "controller_id": "stale", "revision": "1" } : Json).stringify(),
        token="b".repeat(64),
      ).0,
      409,
    )
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        path,
        body.stringify(),
        token="b".repeat(64),
      ).0,
      200,
    )
    let snapshot = c.sync_worker("c".repeat(64), {
      environments: None,
      version: 1,
      state: "starting",
      applied_revision: "1",
    })
    assert_eq(snapshot.isolation_revision, Some("1"))
    c.drain_worker("b".repeat(64), @protocol.parse_decimal(worker.id).unwrap())
    assert_eq(
      @web_testkit.runner_post_json(
        port,
        path,
        body.stringify(),
        token="b".repeat(64),
      ).0,
      409,
    )
  })
}
