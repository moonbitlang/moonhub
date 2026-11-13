///|
pub suberror CliError {
  Invalid(String)
  Rejected(Int32, String)
  InvalidResponse
  TimedOut
}

///|
pub fn validate_server(
  value : String,
  allow_http : Bool,
) -> String raise CliError {
  let server = value.trim_end(chars="/").to_owned()
  let prefix = if server.has_prefix("https://") {
    8
  } else if allow_http && server.has_prefix("http://") {
    7
  } else {
    raise Invalid(
      "HTTPS server required; --allow-http is for trusted local development",
    )
  }
  let authority = server[prefix:]
  guard !authority.is_empty() &&
    authority.length() <= 300 &&
    !authority.contains("/") &&
    !authority.contains("@") &&
    !authority.contains("?") &&
    !authority.contains("#") &&
    authority.iter().all(ch => ch.to_int() > 32 && ch.to_int() < 127) else {
    raise Invalid(
      "server must be an origin without credentials, path, query or fragment",
    )
  }
  server
}

///|
fn check_token(token : String) -> Unit raise CliError {
  guard token.length() == 67 &&
    token.has_prefix("mh_") &&
    token[3:].iter().all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f')) else {
    raise Invalid(
      "a valid mh_ access token is required; create one in Account > Access tokens, then use auth login --server SERVER --token-file FILE (see auth setup)",
    )
  }
}

///|
pub async fn request(
  server : String,
  token : String,
  path : String,
  body : Json?,
  allow_http~ : Bool = false,
  raw_body? : Bytes,
) -> Json {
  let server = validate_server(server, allow_http)
  check_token(token)
  guard path.has_prefix("/") &&
    !path.has_prefix("//") &&
    !path.contains("\r") &&
    !path.contains("\n") else {
    raise Invalid("invalid API path")
  }
  @async.with_timeout(
    30000,
    () => {
      let client = @http.Client(server)
      defer client.close()
      let headers : @http.Headers = {
        "Authorization": "Bearer " + token,
        "Content-Type": if raw_body is Some(_) {
          "application/octet-stream"
        } else {
          "application/json"
        },
      }
      let response = match (body, raw_body) {
        (None, None) => client.get("/-/api/v1" + path, extra_headers=headers)
        (None, Some(bytes)) =>
          client.post("/-/api/v1" + path, bytes, extra_headers=headers)
        (Some(body), None) =>
          client.post(
            "/-/api/v1" + path,
            body.stringify(),
            extra_headers=headers,
          )
        (Some(_), Some(_)) => raise Invalid("choose JSON or a raw request body")
      }
      let bytes : Array[Byte] = []
      while client.read_some(max_len=8192) is Some(chunk) {
        guard bytes.length() + chunk.length() <= 4194304 else {
          raise InvalidResponse
        }
        for byte in chunk {
          bytes.push(byte)
        }
      }
      let json = @json.parse(@utf8.decode(Bytes::from_array(bytes))) catch {
        _ => raise InvalidResponse
      }
      guard response.code >= 200 && response.code < 300 else {
        let message = match json {
          { "error": { "message": String(message), .. }, .. } => message
          _ => "request rejected"
        }
        raise Rejected(response.code, message)
      }
      json
    },
    error=TimedOut,
  )
}

///|
fn escape(value : String) -> String {
  let output = StringBuilder()
  for byte in @utf8.encode(value) {
    let ch = byte.to_int()
    if (ch >= 48 && ch <= 57) ||
      (ch >= 65 && ch <= 90) ||
      (ch >= 97 && ch <= 122) ||
      [45, 46, 95, 126].contains(ch) {
      output.write_char(ch.unsafe_to_char())
    } else {
      let hex = "0123456789ABCDEF"
      output.write_char('%')
      output.write_char(hex[ch / 16].to_int().unsafe_to_char())
      output.write_char(hex[ch % 16].to_int().unsafe_to_char())
    }
  }
  output.to_string()
}

///|
fn decimal(value : String) -> String raise CliError {
  guard !value.is_empty() &&
    value.length() <= 19 &&
    value.iter().all(ch => ch.is_ascii_digit()) &&
    !value.has_prefix("0") else {
    raise Invalid("positive decimal number required")
  }
  ignore(
    @string.parse_int64(value) catch {
      _ => raise Invalid("number out of range")
    },
  )
  value
}

///|
// Terminal display must not execute control sequences from repository content.
pub fn terminal_text(value : String, multiline~ : Bool = false) -> String {
  let result = StringBuilder()
  for ch in value.iter() {
    result.write_char(
      if (ch.to_int() < 32 && !(multiline && (ch == '\n' || ch == '\t'))) ||
        (ch.to_int() >= 127 && ch.to_int() <= 159) {
        ' '
      } else {
        ch
      },
    )
  }
  result.to_string()
}
