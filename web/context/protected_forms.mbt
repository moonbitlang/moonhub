///|
pub fn form_csrf_token(session : String, scope : String) -> String {
  @crypto.bytes_to_hex_string(
    @crypto.hmac(
      @crypto.SHA256::new(),
      @utf8.encode(session),
      @utf8.encode("moonhub:\{scope}:csrf:v1"),
    ),
  )
}

///|
pub fn request_form_token(
  req : @moonback.Request,
  scope : String,
) -> String raise @domain.AppError {
  guard req.cookie().get(session_cookie_name) is Some(session) else {
    raise @domain.Unauthorized(message="login required")
  }
  form_csrf_token(session, scope)
}

///|
fn valid_form_token(expected : String, supplied : String) -> Bool {
  guard expected.length() == 64 && supplied.length() == 64 else { return false }
  let mut difference = 0
  for i = 0; i < expected.length(); i = i + 1 {
    difference = difference | (expected[i].to_int() ^ supplied[i].to_int())
  }
  difference == 0
}

///|
pub async fn read_form(req : @moonback.Request) -> Map[String, String] {
  let bytes = FixedArray::make(65537, b'\x00')
  let reader = req.body.reader(no_buffer=true)
  let mut length = 0
  while length < bytes.length() {
    let count = reader.read(
      bytes,
      offset=length,
      max_len=bytes.length() - length,
    )
    if count == 0 {
      break
    }
    length = length + count
  }
  guard length <= 65536 else {
    raise @domain.BadRequest(message="form is too large")
  }
  let body = @utf8.decode(Bytes::from_array(bytes)[:length]) catch {
    _ => raise @domain.BadRequest(message="invalid form encoding")
  }
  parse_form(body)
}

///|
pub async fn protected_form(
  req : @moonback.Request,
  scope : String,
) -> Map[String, String] {
  guard req.headers.get("Sec-Fetch-Site") != Some("cross-site") else {
    raise @domain.Forbidden(message="cross-site request rejected")
  }
  let form = read_form(req)
  guard valid_form_token(
    request_form_token(req, scope),
    form.get("csrf_token").unwrap_or(""),
  ) else {
    raise @domain.Forbidden(
      message="invalid request token; reload the page and try again",
    )
  }
  form
}

///|
pub fn private_page_headers(
  location? : String,
  refresh? : Bool = false,
) -> @moonback.Headers {
  let headers = @moonback.MutHeaders::from({
    "cache-control": "no-store",
    "content-security-policy": "frame-ancestors 'none'; form-action 'self'; base-uri 'none'",
    "x-frame-options": "DENY",
    "referrer-policy": "same-origin",
  })
  if location is Some(location) {
    headers.set("location", location)
  }
  if refresh {
    headers.set("refresh", "2")
  }
  headers.to_immut()
}
