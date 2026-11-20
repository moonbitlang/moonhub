///|
pub async fn runner_post_json(
  port : Int32,
  path : String,
  body : String,
  token~ : String = "",
  cookie~ : String = "",
  content_type~ : String = "application/json",
) -> (Int32, Json) {
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let headers : Map[@http.CaseInsensitiveString, String] = {
    "Content-Type": content_type,
  }
  if !token.is_empty() {
    headers["Authorization"] = "Bearer " + token
  }
  if !cookie.is_empty() {
    headers["Cookie"] = cookie
  }
  let response = client.post(
    "/-/runner-api/v1" + path,
    body,
    extra_headers=headers,
  )
  let text = client.read_all().text()
  assert_true(response.headers.get("cache-control") is Some("no-store"))
  assert_true(response.headers.get("location") is None)
  assert_true(
    response.headers
    .get("content-type")
    .unwrap_or("")
    .has_prefix("application/json"),
  )
  (response.code, @json.parse(text))
}
