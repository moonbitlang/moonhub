///|
pub fn authorize_image_form(req : @moonback.Request) -> Unit raise {
  guard req.headers.get("Sec-Fetch-Site") != Some("cross-site") else {
    raise @domain.Forbidden(message="cross-site request rejected")
  }
  let scope = req.headers.get("X-CSRF-Scope").unwrap_or("").to_owned()
  guard ["issues", "merge-requests"].contains(scope) &&
    valid_form_token(
      request_form_token(req, scope),
      req.headers.get("X-CSRF-Token").unwrap_or("").to_owned(),
    ) else {
    raise @domain.Forbidden(
      message="invalid request token; reload the page and try again",
    )
  }
}

///|
pub async fn read_bounded_body(req : @moonback.Request, limit : Int32) -> Bytes {
  let chunks : Array[Bytes] = []
  let mut size = 0
  let reader = req.body.reader(no_buffer=true)
  @async.with_timeout(
    10000,
    () => {
      while reader.read_some(max_len=65536) is Some(chunk) {
        size = size + chunk.length()
        guard size <= limit else {
          raise @domain.BadRequest(message="request body is too large")
        }
        chunks.push(chunk)
      }
    },
    error=@domain.BadRequest(message="request body timed out"),
  )
  let bytes = FixedArray::make(size, b'\x00')
  let mut offset = 0
  for chunk in chunks {
    for byte in chunk {
      bytes[offset] = byte
      offset = offset + 1
    }
  }
  Bytes::from_array(bytes)
}
