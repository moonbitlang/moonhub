///|
async test "secret API requires write scope and repository management returns metadata only and rejects stale writes" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let read = @identity.create_access_token(pool, alice, "read", "read", 1)
    let write = @identity.create_access_token(pool, alice, "write", "write", 1)
    let outside = @identity.create_access_token(pool, bob, "write", "write", 1)
    let route = "/repos/alice/demo/secrets/TOKEN"
    let body : Json = {
      "value": "api-private-value",
      "branch": "master",
      "workflow": ".github/workflows/publish.yml",
      "version": "0",
    }
    assert_eq(api_test_request(port, route, read, Some(body)).0, 403)
    assert_eq(api_test_request(port, route, outside, Some(body)).0, 404)
    let (status, result) = api_test_request(port, route, write, Some(body))
    assert_eq(status, 200)
    assert_true(result is { "name": String("TOKEN"), .. })
    assert_true(!result.stringify().contains("api-private-value"))
    assert_true(!(result is { "value": _, .. }))
    let (_, listed) = api_test_request(
      port,
      "/repos/alice/demo/secrets",
      read,
      None,
    )
    assert_true(!listed.stringify().contains("api-private-value"))
    assert_eq(api_test_request(port, route, write, Some(body)).0, 409)
    guard result is { "version": String(version), .. } else {
      fail("missing revision")
    }
    let (saved, rotated) = api_test_request(
      port,
      route,
      write,
      Some({
        "value": "rotated-private-value",
        "branch": "master",
        "workflow": ".github/workflows/publish.yml",
        "version": version,
      }),
    )
    assert_eq(saved, 200)
    assert_eq(
      api_test_request(
        port,
        route + "/delete",
        write,
        Some({ "version": version }),
      ).0,
      409,
    )
    guard rotated is { "version": String(latest), .. } else {
      fail("missing revision")
    }
    assert_eq(
      api_test_request(
        port,
        route + "/delete",
        write,
        Some({ "version": latest }),
      ).0,
      200,
    )
  })
}
