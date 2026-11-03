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
priv struct LogMaskNode {
  edges : Map[Int32, Int32]
  depth : Int32
  mut failure : Int32
  mut longest : Int32
}

///|
// Aho-Corasick failure links make repeated-prefix matching linear in the log
// length instead of restarting a potentially 16 KiB comparison at each unit.
// Match spans are unioned so overlapping credentials are masked completely.
fn mask_log(text : String, masks : Array[String]) -> (String, String) {
  let nodes : Array[LogMaskNode] = [
    { edges: Map([]), depth: 0, failure: 0, longest: 0, },
  ]
  for mask in masks {
    let mut state = 0
    for index = 0; index < mask.length(); index = index + 1 {
      let unit = mask[index].to_int()
      state = match nodes[state].edges.get(unit) {
        Some(next) => next
        None => {
          let next = nodes.length()
          nodes[state].edges[unit] = next
          nodes.push({
            edges: Map([]),
            depth: nodes[state].depth + 1,
            failure: 0,
            longest: 0,
          })
          next
        }
      }
    }
    if !mask.is_empty() {
      nodes[state].longest = mask.length()
    }
  }
  let queue : Array[Int32] = nodes[0].edges.values().collect()
  for index = 0; index < queue.length(); index = index + 1 {
    let state = queue[index]
    for unit, child in nodes[state].edges {
      let mut fallback = nodes[state].failure
      while fallback != 0 && !nodes[fallback].edges.contains(unit) {
        fallback = nodes[fallback].failure
      }
      let failure = nodes[fallback].edges.get(unit).unwrap_or(0)
      nodes[child].failure = failure
      nodes[child].longest = Int32::max(
        nodes[child].longest,
        nodes[failure].longest,
      )
      queue.push(child)
    }
  }
  let ends : Array[Int32] = Array::make(text.length(), 0)
  let mut state = 0
  for index = 0; index < text.length(); index = index + 1 {
    let unit = text[index].to_int()
    while state != 0 && !nodes[state].edges.contains(unit) {
      state = nodes[state].failure
    }
    state = nodes[state].edges.get(unit).unwrap_or(0)
    let length = nodes[state].longest
    if length > 0 {
      let start = index + 1 - length
      ends[start] = Int32::max(ends[start], index + 1)
    }
  }
  // Only a proper prefix of a longer mask must wait for another chunk.
  while state != 0 && nodes[state].edges.is_empty() {
    state = nodes[state].failure
  }
  let pending_start = text.length() - nodes[state].depth
  let mut cut = pending_start
  for start = 0; start < pending_start; start = start + 1 {
    // Preserve one complete match across the original pending boundary. Do
    // not extend through an entire chain of overlapping matches: its length
    // could be unbounded even though each individual secret is bounded.
    if ends[start] > pending_start {
      cut = Int32::min(cut, start)
    }
  }
  let spans : Array[(Int32, Int32)] = []
  let mut index = 0
  while index < text.length() {
    if ends[index] == 0 {
      index += 1
      continue
    }
    let start = index
    let mut end = ends[index]
    index += 1
    while index < end {
      end = Int32::max(end, ends[index])
      index += 1
    }
    spans.push((start, end))
  }
  let output = StringBuilder()
  let mut cursor = 0
  for (start, end) in spans {
    if start >= cut {
      break
    }
    output.write_string(text[cursor:start].to_owned())
    output.write_string("***")
    cursor = Int32::min(end, cut)
  }
  output.write_string(text[cursor:cut].to_owned())
  (output.to_string(), text[cut:].to_owned())
}
