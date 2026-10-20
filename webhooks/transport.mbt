///|
pub(all) struct Policy {
  allowed_origins : Array[String]
}

///|
pub fn Policy::new(allowed_origins~ : Array[String] = []) -> Policy {
  { allowed_origins, }
}

///|
priv struct Target {
  host : String
  authority : String
  port : Int32
  path : String
  tls : Bool
  private_allowed : Bool
}

///|
fn parse_target(url : String, policy : Policy) -> Target raise {
  guard url.length() <= 2048 &&
    url.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) &&
    !url.contains("#") &&
    !url.contains("\\") else {
    raise @domain.BadRequest(
      message="webhook URL must be an ASCII HTTP(S) URL without fragments or credentials",
    )
  }
  let (tls, rest) = if url.strip_prefix("https://") is Some(rest) {
    (true, rest)
  } else if url.strip_prefix("http://") is Some(rest) {
    (false, rest)
  } else {
    raise @domain.BadRequest(message="HTTPS webhook URL required")
  }
  let end = rest.find("/").unwrap_or(rest.length())
  let authority = rest[:end].to_owned()
  let origin = (if tls { "https://" } else { "http://" }) + authority
  let private_allowed = policy.allowed_origins.contains(origin)
  guard tls || private_allowed else {
    raise @domain.BadRequest(
      message="HTTP requires an administrator-allowed origin",
    )
  }
  let (host, port) = match authority.split_once(":") {
    None => (authority, if tls { 443 } else { 80 })
    Some((host, port)) =>
      (
        host.to_owned(),
        @string.parse_int(port) catch {
          _ => raise @domain.BadRequest(message="invalid webhook port")
        },
      )
  }
  guard !host.is_empty() &&
    host.length() <= 253 &&
    port >= 1 &&
    port <= 65535 &&
    host
    .split(".")
    .all(part => {
      !part.is_empty() &&
      part.length() <= 63 &&
      !part.has_prefix("-") &&
      !part.has_suffix("-") &&
      part
      .iter()
      .all(ch => ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '-')
    }) else {
    raise @domain.BadRequest(
      message="webhook URL requires a DNS hostname or IPv4 address and valid port",
    )
  }
  {
    host,
    authority,
    port,
    path: if end == rest.length() {
      "/"
    } else {
      rest[end:].to_owned()
    },
    tls,
    private_allowed,
  }
}

///|
fn public_address(addr : @socket.Addr) -> Bool {
  if addr.is_ipv6() {
    return false
  }
  let ip = addr.ip()
  let a = ip >> 24
  let b = (ip >> 16) & 255
  !(a == 0 ||
  a == 10 ||
  a == 127 ||
  a >= 224 ||
  (a == 100 && b >= 64 && b <= 127) ||
  (a == 169 && b == 254) ||
  (a == 172 && b >= 16 && b <= 31) ||
  (a == 192 && (b == 168 || b == 0 || b == 2)) ||
  (a == 198 && (b == 18 || b == 19 || b == 51)) ||
  (a == 203 && b == 0))
}

///|
pub fn signature(secret : String, body : String) -> String {
  "sha256=" +
  @crypto.bytes_to_hex_string(
    @crypto.hmac(
      @crypto.SHA256::new(),
      @utf8.encode(secret)[:],
      @utf8.encode(body)[:],
    ),
  )
}

///|
priv suberror DeliveryError {
  Rejected
}

///|
async fn[T : @io.Reader + @io.Writer] post_request(
  stream : T,
  target : Target,
  kind : String,
  delivery_id : Int64,
  event_id : Int64,
  secret : String,
  body : String,
) -> Int32 {
  let request = "POST \{target.path} HTTP/1.1\r\nHost: \{target.authority}\r\nUser-Agent: MoonHub-Webhooks/1\r\nContent-Type: application/json\r\nContent-Length: \{@utf8.encode(body).length()}\r\nConnection: close\r\nX-MoonHub-Event: \{kind}\r\nX-MoonHub-Delivery: \{delivery_id}\r\nX-MoonHub-Event-ID: \{event_id}\r\nX-MoonHub-Signature-256: \{signature(secret,body)}\r\n\r\n\{body}"
  @io.Writer::write(stream, request)
  read_response_status(stream)
}

///|
// Informational responses can precede the final status, even in one read.
// Count only header bytes, across every block, under the caller's deadline.
async fn[R : @io.Reader] read_response_status(stream : R) -> Int32 {
  let block : Array[Byte] = []
  let mut header_bytes = 0
  while @io.Reader::read_some(stream, max_len=1024) is Some(chunk) {
    for byte in chunk {
      header_bytes += 1
      guard header_bytes <= 32768 else { raise Rejected }
      block.push(byte)
      let length = block.length()
      if length < 4 ||
        block[length - 4] != b'\r' ||
        block[length - 3] != b'\n' ||
        block[length - 2] != b'\r' ||
        block[length - 1] != b'\n' {
        continue
      }
      let headers = @utf8.decode(Bytes::from_array(block)[:length - 4])
      let line = headers.split("\r\n").collect()[0]
      let parts = line.split(" ").collect()
      guard parts.length() >= 2 &&
        ["HTTP/1.0", "HTTP/1.1"].contains(parts[0].to_owned()) &&
        parts[1].length() == 3 &&
        parts[1].iter().all(ch => ch.is_ascii_digit()) else {
        raise Rejected
      }
      let code = @string.parse_int(parts[1]) catch { _ => raise Rejected }
      guard code >= 100 && code <= 599 && code != 101 else { raise Rejected }
      if code >= 200 {
        return code
      }
      block.clear()
    }
  }
  raise Rejected
}

///|
async fn send_delivery(
  target : Target,
  kind : String,
  delivery_id : Int64,
  event_id : Int64,
  secret : String,
  body : String,
  authorize : () -> Unit raise,
) -> Int32 {
  // Resolve once and connect to this exact checked address, preventing DNS rebinding.
  let addr = @socket.Addr::resolve(
    target.host,
    port=target.port,
    protocol=OnlyV4,
  )
  guard target.private_allowed || public_address(addr) else { raise Rejected }
  let tcp = @socket.Tcp::connect(addr)
  defer tcp.close()
  if target.tls {
    let tls = @tls.Tls::client(tcp, host=target.host, trust=SystemRoot)
    defer tls.close()
    authorize()
    post_request(tls, target, kind, delivery_id, event_id, secret, body)
  } else {
    authorize()
    post_request(tcp, target, kind, delivery_id, event_id, secret, body)
  }
}
