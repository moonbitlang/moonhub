///|
pub async fn profile_form_token(port : Int32, cookie : @http.Cookie) -> String {
  let (response, body) = http_get_path_with_cookie(
    port, "/-/settings/profile", cookie,
  )
  assert_eq(response.code, 200)
  assert_true(response.headers.get("cache-control") is Some("no-store"))
  extract_attr(body, "name=\"csrf_token\"", "value=\"")
}
