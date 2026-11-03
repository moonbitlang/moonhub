///|
fn secret_masks(value : String) -> Array[String] {
  let masks : Map[String, Bool] = Map([(value, true)])
  for line in value.split("\n") {
    let line = line.trim_end(chars="\r").to_owned()
    if !line.is_empty() {
      masks[line] = true
    }
  }
  // Credentials files commonly contain a token as a JSON string. Also mask
  // its decoded value when a command logs the token without the JSON wrapper.
  let json = Some(@json.parse(value)) catch { _ => None }
  let pending : Array[Json] = []
  if json is Some(json) {
    pending.push(json)
  }
  while pending.pop() is Some(item) {
    match item {
      String(text) => if !text.is_empty() { masks[text] = true }
      Object(fields) =>
        for _, value in fields {
          pending.push(value)
        }
      Array(items) => pending.push_iter(items.iter())
      _ => ()
    }
  }
  masks.keys().collect()
}

///|
fn mask_log(text : String, masks : Array[String]) -> (String, String) {
  let output = StringBuilder()
  let mut rest = text[:]
  while !rest.is_empty() {
    let mut matched = 0
    let mut partial = false
    for mask in masks {
      if rest.has_prefix(mask) {
        matched = Int32::max(matched, mask.length())
      } else if mask.has_prefix(rest) {
        partial = true
      }
    }
    // Delay ambiguous prefixes, including a short mask that might grow into
    // a longer overlapping one. Unmasked prefixes stay out of readable chunks.
    if partial {
      return (output.to_string(), rest.to_owned())
    }
    if matched > 0 {
      output.write_string("***")
      rest = rest[matched:]
    } else {
      let ch = rest.iter().next().unwrap()
      output.write_char(ch)
      rest = rest[ch.to_string().length():]
    }
  }
  (output.to_string(), "")
}
