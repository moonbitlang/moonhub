///|
/// Timestamp presentation shared by browser pages. SQLite instants are UTC;
/// ISO timestamps retain their offset. Date-only metadata is a calendar date.
pub fn timestamp(value : String, relative~ : Bool = false) -> @moonback.Html {
  Html(b => {
    if value.is_empty() || value.length() == 10 {
      b <+ "\{value}"
    } else {
      let datetime = value.replace_all(old=" ", new="T")
      let (datetime, fallback) = if value.length() == 19 {
        (datetime + "Z", value + " UTC")
      } else {
        (datetime, value)
      }
      b <+ "<time datetime=\"\{datetime}\" data-local-time"
      if relative {
        b <+ " data-relative-time"
      }
      b <+ " title=\"\{fallback}\">\{fallback}</time>"
    }
  })
}
