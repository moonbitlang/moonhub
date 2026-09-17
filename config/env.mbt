///|
pub async fn load_dotenv(path : String) -> Unit {
  let text = @fs.read_file(path).text() catch { _ => return }
  for raw_line in text.split("\n") {
    let line = raw_line.trim()
    if line.is_empty() || line.has_prefix("#") {
      continue
    }
    match line.split_once("=") {
      Some((name, value)) =>
        if !name.is_empty() {
          @env.set_env_var(name.to_owned(), value.to_owned())
        }
      None => ()
    }
  }
}

///|
pub fn env_value(name : String) -> String? {
  match @env.get_env_var(name) {
    Some(value) => {
      let value = value.trim().to_owned()
      if value.is_empty() {
        None
      } else {
        Some(value)
      }
    }
    None => None
  }
}
