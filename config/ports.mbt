///|
pub fn parse_port(s : String) -> UInt16? {
  let mut n = 0
  for ch in s {
    if ch < '0' || ch > '9' {
      return None
    }
    n = n * 10 + ch.to_int() - '0'.to_int()
  }
  if n > 0 && n <= 65535 {
    Some(n.to_uint16())
  } else {
    None
  }
}
