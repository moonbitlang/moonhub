///|
async test "execution APIs enforce administrator environment access and execute-scoped repository policy" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let read = @identity.create_access_token(pool, alice, "read", "read", 1)
    let write = @identity.create_access_token(pool, alice, "write", "write", 1)
    let execute = @identity.create_access_token(
      pool, alice, "execute", "execute", 1,
    )
    let admin_read = @identity.create_access_token(
      pool, admin, "adminread", "read", 1,
    )
    let admin_write = @identity.create_access_token(
      pool, admin, "adminwrite", "write", 1,
    )
    let outside = @identity.create_access_token(
      pool, bob, "outside", "execute", 1,
    )
    let base = "/admin/execution-environments"
    assert_eq(api_test_request(port, base, read, None).0, 403)
    assert_eq(api_test_request(port, base, admin_read, None).0, 200)
    let config : Json = {
      "label": "ubuntu-24.04",
      "architecture": "x64",
      "environment_version": "v1",
      "routing": "restricted",
      "restricted_provider": "ordinary",
      "linux_ci_provider": "",
    }
    assert_eq(
      api_test_request(
        port,
        base + "/ubuntu-x64",
        admin_read,
        Some({ "revision": "0", "config": config }),
      ).0,
      403,
    )
    let c = @pipeline.Coordinator::new(pool)
    ignore(
      c.create_provider(
        admin,
        "ordinary",
        "a".repeat(64),
        ["self-hosted", "linux", "x64", "ubuntu-24.04"],
        [],
      ),
    )
    ignore(
      c.register_runner("a".repeat(64), {
        version: 1,
        name: "ordinary",
        mode: "docker",
        provider_token: "b".repeat(64),
        schema: [],
        defaults: Map([]),
      }),
    )
    assert_eq(
      api_test_request(
        port,
        base + "/ubuntu-x64",
        admin_write,
        Some({ "revision": "0", "config": config }),
      ).0,
      200,
    )
    assert_eq(
      api_test_request(
        port,
        base + "/ubuntu-x64",
        admin_write,
        Some({ "revision": "0", "config": config }),
      ).0,
      409,
    )
    let route = "/repos/alice/demo/execution-policy"
    assert_eq(api_test_request(port, route, read, None).0, 200)
    let body : Json = { "revision": "0", "capability_retry": true }
    assert_eq(api_test_request(port, route, write, Some(body)).0, 403)
    assert_eq(api_test_request(port, route, outside, Some(body)).0, 404)
    let (status, saved) = api_test_request(port, route, execute, Some(body))
    assert_eq(status, 200)
    assert_true(
      saved is { "revision": String("1"), "capability_retry": True, .. },
    )
    assert_eq(api_test_request(port, route, execute, Some(body)).0, 409)
    assert_eq(
      api_test_request(
        port,
        route,
        execute,
        Some({ "revision": "1", "capability_retry": "yes" }),
      ).0,
      400,
    )
    assert_eq(
      api_test_request(
        port,
        route,
        execute,
        Some({
          "revision": "1",
          "capability_retry": false,
          "provider": "ordinary",
        }),
      ).0,
      400,
    )
  })
}
