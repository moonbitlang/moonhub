///|
fn percent_decode(input : StringView) -> String {
  // Form bodies use '+' for spaces; URL paths preserve literal '+'.
  @percent.decode_lossy(input.to_owned().replace_all(old="+", new=" "))
}

///|
fn decode_url_path(input : String) -> String raise @domain.AppError {
  @percent.decode(input) catch {
    _ => raise @domain.BadRequest(message="invalid path encoding")
  }
}

///|
pub fn url_escape_path(s : String) -> String {
  s.split("/").map(segment => @percent.encode(segment)).join("/")
}
