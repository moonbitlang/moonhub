///|
async test "webhook API enforces manager permissions and never returns secrets" {
  @web_testkit.with_ssh_settings_app((port, pool, _, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let token = @identity.create_access_token(
      pool, actor, "Webhook API", "write", 1,
    )
    let read = @identity.create_access_token(
      pool, actor, "Webhook read", "read", 1,
    )
    let base = "http://127.0.0.1:\{port}"
    let client = @http.Client(base)
    defer client.close()
    let response = client.post(
      "/-/api/v1/repos/alice/demo/hooks",
      (
        {
          "url": "https://example.com/hook",
          "secret": "0123456789abcdef",
          "events": ["push"],
          "active": true,
        } : Json).stringify(),
      extra_headers={
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
      },
    )
    assert_eq(response.code, 200)
    let body = client.read_all().text()
    assert_false(body.contains("0123456789abcdef"))
    assert_true(body.contains("example.com"))
    let client = @http.Client(base)
    defer client.close()
    let response = client.post(
      "/-/api/v1/repos/alice/demo/hooks/1/ping",
      "{}",
      extra_headers={
        "Authorization": "Bearer " + read,
        "Content-Type": "application/json",
      },
    )
    assert_eq(response.code, 403)
    ignore(client.read_all())
    let client = @http.Client(base)
    defer client.close()
    let response = client.get("/-/api/v1/repos/alice/demo/hooks/1/deliveries", extra_headers={
      "Authorization": "Bearer " + read,
    })
    assert_eq(response.code, 200)
    assert_false(client.read_all().text().contains("0123456789abcdef"))
  })
}
