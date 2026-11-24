///|
async test "dependency grant APIs require administrators and never return download credentials" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let actor = @identity.active_user_by_name(pool, "alice")
    let token = @identity.create_access_token(
      pool, admin, "dependency admin", "write", 1,
    )
    let ordinary = @identity.create_access_token(
      pool, actor, "repository manager", "write", 1,
    )
    let route = "/repos/alice/demo/dependency-grants"
    let body : Json = {
      "kind": "github",
      "target": "private/action",
      "ref": "",
      "credential": "private-download-value",
      "version": "0",
    }
    assert_eq(api_test_request(port, route, ordinary, Some(body)).0, 403)
    assert_eq(api_test_request(port, route, token, Some(body)).0, 200)
    assert_eq(api_test_request(port, route, token, Some(body)).0, 409)
    let (status, listed) = api_test_request(port, route, token, None)
    assert_eq(status, 200)
    assert_true(listed.stringify().contains("private/action"))
    assert_true(!listed.stringify().contains("private-download-value"))
    assert_eq(api_test_request(port, route, ordinary, None).0, 403)
    let remove : Json = {
      "kind": "github",
      "target": "private/action",
      "ref": "",
      "version": "1",
      "delete": true,
    }
    assert_eq(
      api_test_request(port, route, token, Some(remove), prefix="/api/v3").0,
      200,
    )
    assert_true(
      api_test_request(port, route, token, None).1
      is { "items": Array(items), .. } &&
      items.is_empty(),
    )
  })
}
