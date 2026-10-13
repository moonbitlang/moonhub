///|
fn hex_value(ch : UInt16) -> Int32? {
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
pub fn url_escape_path(s : String) -> String {
  s
  .replace_all(old=" ", new="%20")
  .replace_all(old="#", new="%23")
  .replace_all(old="?", new="%3F")
}
