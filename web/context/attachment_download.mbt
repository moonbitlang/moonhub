///|
// RFC 6266: keep the fallback ASCII and encode the original UTF-8 filename.
pub fn attachment_disposition(filename : String, inline~ : Bool) -> String {
  if inline {
    return "inline"
  }
  let encoded = StringBuilder()
  let hex = "0123456789ABCDEF"
  for byte in @utf8.encode(filename) {
    let ch = byte.to_int()
    if (ch >= 48 && ch <= 57) ||
      (ch >= 65 && ch <= 90) ||
      (ch >= 97 && ch <= 122) ||
      [45, 46, 95, 126].contains(ch) {
      encoded.write_char(ch.unsafe_to_char())
    } else {
      encoded.write_char('%')
      encoded.write_char(hex[ch / 16].to_int().unsafe_to_char())
      encoded.write_char(hex[ch % 16].to_int().unsafe_to_char())
    }
  }
  "attachment; filename=\"attachment\"; filename*=UTF-8''\{encoded.to_string()}"
}
