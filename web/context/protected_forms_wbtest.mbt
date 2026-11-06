///|
async test "protected form limits preserve defaults custom boundaries and CSRF checks" {
  let assets = @web_assets.load_entry_to_asset_path_map(
    @web_testkit.test_assets_root,
  )
  let app = @moonback.App(
    Module(ctx => {
      ctx.add_middleware(app_error_middleware(assets))
      ctx.post("/default", async fn(req, res) {
        let form = protected_form(req, "body-limit")
        res.send_text(form.get("value").unwrap_or("").length().to_string())
      })
      ctx.post("/expanded", async fn(req, res) {
        let form = protected_form(req, "body-limit", limit=212992)
        res.send_text(form.get("value").unwrap_or("").length().to_string())
      })
    }),
  )
  defer app.close()
  @async.with_task_group(group => {
    let listener = @moonback.listen(port=0)
    let server = group.spawn(() => app.serve(listener))
    defer server.cancel()
    let port = listener.addr.port()
    let session = "bounded-form-session"
    let token = form_csrf_token(session, "body-limit")
    let prefix = "csrf_token=" + token + "&value="
    for (path, limit) in [("/default", 65536), ("/expanded", 212992)] {
      let maximum = prefix + "x".repeat(limit - prefix.length())
      for
        (body, status, message) in [
          (maximum, 200, (limit - prefix.length()).to_string()),
          (maximum + "x", 400, "form is too large"),
          (
            "csrf_token=invalid&value=" + "x".repeat(limit - 25),
            403,
            "invalid request token",
          ),
        ] {
        let client = @http.Client("http://127.0.0.1:\{port}")
        defer client.close()
        let response = client.post(path, body, extra_headers={
          "Content-Type": "application/x-www-form-urlencoded",
          "Cookie": "\{session_cookie_name}=\{session}",
        })
        let response_body = client.read_all().text()
        assert_eq(response.code, status, msg=path)
        assert_true(response_body.contains(message), msg=path)
      }
      let client = @http.Client("http://127.0.0.1:\{port}")
      defer client.close()
      let cross_site = client.post(path, maximum, extra_headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "Cookie": "\{session_cookie_name}=\{session}",
        "Sec-Fetch-Site": "cross-site",
      })
      assert_eq(cross_site.code, 403)
      assert_true(
        client.read_all().text().contains("cross-site request rejected"),
      )
      let invalid_encoding = client.post(path, b"\xff", extra_headers={
        "Content-Type": "application/x-www-form-urlencoded",
        "Cookie": "\{session_cookie_name}=\{session}",
      })
      assert_eq(invalid_encoding.code, 400)
      assert_true(client.read_all().text().contains("invalid form encoding"))
    }
  })
}
