///|
async test "variable API exposes readable values and protects revision-bound mutations" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let read = @identity.create_access_token(pool, alice, "read", "read", 1)
    let write = @identity.create_access_token(pool, alice, "write", "write", 1)
    let outsider = @identity.create_access_token(
      pool, bob, "outside", "write", 1,
    )
    let route = "/repos/alice/demo/variables/region"
    let body : Json = { "value": "ap-northeast-1", "version": "0" }
    assert_eq(api_test_request(port, route, read, Some(body)).0, 403)
    assert_eq(api_test_request(port, route, outsider, Some(body)).0, 404)
    let (status, saved) = api_test_request(port, route, write, Some(body))
    assert_eq(status, 200)
    guard saved
      is {
        "name": String("REGION"),
        "value": String("ap-northeast-1"),
        "version": String(version),
        ..
      } else {
      fail("missing readable variable")
    }
    let (listed, values) = api_test_request(
      port,
      "/repos/alice/demo/variables",
      read,
      None,
    )
    assert_eq(listed, 200)
    assert_true(values.stringify().contains("ap-northeast-1"))
    assert_eq(api_test_request(port, route, write, Some(body)).0, 409)
    let (updated, empty) = api_test_request(
      port,
      route,
      write,
      Some({ "value": "", "version": version }),
    )
    assert_eq(updated, 200)
    guard empty is { "value": String(""), "version": String(latest), .. } else {
      fail("empty value rejected")
    }
    assert_eq(
      api_test_request(
        port,
        route + "/delete",
        write,
        Some({ "version": version }),
      ).0,
      409,
    )
    assert_eq(
      api_test_request(
        port,
        route + "/delete",
        write,
        Some({ "version": latest }),
      ).0,
      200,
    )
    assert_true(
      api_test_request(port, "/repos/alice/demo/variables", read, None).1
      is { "items": Array(items), .. } &&
      items.is_empty(),
    )
  })
}

///|
async test "variable API carries maximum escaped UTF8 values and bounds wrappers" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let token = @identity.create_access_token(pool, actor, "vars", "write", 1)
    // JSON control escaping expands each byte sixfold, above the default body limit.
    let value = "\u{0001}".repeat(40000) + "x".repeat(9152)
    let body : Json = { "value": value, "version": "0" }
    assert_true(@utf8.encode(body.stringify()).length() > 65536)
    let (status, result) = api_test_request(
      port,
      "/repos/alice/demo/variables/PAYLOAD",
      token,
      Some(body),
    )
    assert_eq(status, 200)
    guard result is { "version": String(version), "value": String(actual), .. } else {
      fail("missing value")
    }
    assert_eq(actual, value)
    assert_eq(
      api_test_request(
        port,
        "/repos/alice/demo/variables/PAYLOAD",
        token,
        Some({ "value": value + "x", "version": version }),
      ).0,
      400,
    )
    let (oversized, error) = api_test_request(
      port,
      "/repos/alice/demo/variables/PAYLOAD",
      token,
      Some({ "value": "x".repeat(327680), "version": version }),
    )
    assert_eq(oversized, 400)
    assert_true(error.stringify().contains("request body is too large"))
  })
}
