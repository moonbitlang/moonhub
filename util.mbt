///|
fn trim_trailing_slash(path : String) -> String {
  let mut out = path
  while out.length() > 1 && out.has_suffix("/") {
    out = out[:out.length() - 1].to_owned()
  }
  out
}

///|
fn strip_git_suffix(name : String) -> String? {
  match name.strip_suffix(".git") {
    Some(v) => Some(v.to_owned())
    None => None
  }
}

///|
fn valid_segment(s : String) -> Bool {
  !s.is_empty() && !s.contains("/") && s != "." && s != ".."
}

///|
const PUBLIC_ASSETS_OWNER : String = "assets"

///|
fn valid_repo_owner(s : String) -> Bool {
  valid_segment(s) && s != PUBLIC_ASSETS_OWNER
}

///|
fn valid_name_key(s : String) -> Bool {
  guard !s.is_empty() && s.length() <= 63 else { return false }
  for i, ch in s {
    if i == 0 {
      guard ch.is_ascii_lowercase() || ch.is_ascii_digit() else { return false }
    } else {
      guard ch.is_ascii_lowercase() ||
        ch.is_ascii_digit() ||
        ch == '-' ||
        ch == '_' else {
        return false
      }
    }
  }
  s != PUBLIC_ASSETS_OWNER
}

///|
fn valid_email(s : String) -> Bool {
  s.length() <= 254 &&
  s == s.to_lower() &&
  s.iter().all(ch => ch.to_int() > 32 && ch.to_int() != 127) &&
  @core.Mailbox::address_only(s) is Ok(_)
}

///|
fn normalize_email(s : String) -> String {
  s.trim().to_owned().to_lower()
}

///|
fn valid_team_invite_role(role : String) -> Bool {
  role == "admin" || role == "member"
}

///|
fn hex_value(ch : UInt16) -> Int? {
  let code = ch.to_int()
  let zero = '0'.to_int()
  let nine = '9'.to_int()
  let lower_a = 'a'.to_int()
  let lower_f = 'f'.to_int()
  let upper_a = 'A'.to_int()
  let upper_f = 'F'.to_int()
  if code >= zero && code <= nine {
    Some(code - zero)
  } else if code >= lower_a && code <= lower_f {
    Some(code - lower_a + 10)
  } else if code >= upper_a && code <= upper_f {
    Some(code - upper_a + 10)
  } else {
    None
  }
}

///|
fn percent_decode(input : StringView) -> String {
  let out : Array[Byte] = []
  let len = input.length()
  let mut i = 0
  while i < len {
    let ch = input.code_unit_at(i)
    if ch.to_int() == '+'.to_int() {
      out.push(b' ')
      i += 1
    } else if ch.to_int() == '%'.to_int() && i + 2 < len {
      match
        (
          hex_value(input.code_unit_at(i + 1)),
          hex_value(input.code_unit_at(i + 2)),
        ) {
        (Some(hi), Some(lo)) => {
          out.push((hi * 16 + lo).to_byte())
          i += 3
        }
        _ => {
          out.push(ch.to_byte())
          i += 1
        }
      }
    } else {
      let next = if i + 1 < len &&
        input.code_unit_at(i).is_leading_surrogate() &&
        input.code_unit_at(i + 1).is_trailing_surrogate() {
        i + 2
      } else {
        i + 1
      }
      out.push_iter(@utf8.encode(input[i:next]).iter())
      i = next
    }
  }
  @utf8.decode_lossy(Bytes::from_array(out))
}

///|
fn url_escape_path(s : String) -> String {
  s
  .replace_all(old=" ", new="%20")
  .replace_all(old="#", new="%23")
  .replace_all(old="?", new="%3F")
}

///|
fn split_lines(s : String) -> Array[String] {
  let lines : Array[String] = []
  for line in s.split("\n") {
    let line = match line.strip_suffix("\r") {
      Some(v) => v.to_owned()
      None => line.to_owned()
    }
    if !line.is_empty() {
      lines.push(line)
    }
  }
  lines
}
