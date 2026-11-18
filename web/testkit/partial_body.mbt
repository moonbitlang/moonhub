///|
// Hold the final byte until the real handler has claimed its body stream.
pub async fn partial_body_request(
  port : Int32,
  path : String,
  body : String,
  headers : @http.Headers,
  started : @async.Semaphore,
  while_reading : async () -> Unit,
) -> (@http.Response, String) {
  let body = @utf8.encode(body)
  assert_true(body.length() > 1)
  let headers = headers.copy()
  headers["Content-Length"] = body.length().to_string()
  headers["X-Moonhub-Test-Partial-Body"] = "1"
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  client.request(Post, path, extra_headers=headers)
  client.write(body[:body.length() - 1])
  client.flush()
  @async.with_timeout(5000, () => started.acquire())
  while_reading()
  client.write(body[body.length() - 1:])
  let response = client.end_request()
  (response, client.read_all().text())
}
