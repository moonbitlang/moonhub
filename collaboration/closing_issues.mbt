///|
// Parse only canonical, repository-local references following a closing keyword.
// A clause may contain comma/and-separated references; unrelated prose ends it.
fn closing_issue_clause(chars : Array[Char], start : Int32) -> Array[Int64] {
  let numbers : Array[Int64] = []
  let mut cursor = start
  while cursor < chars.length() &&
        (chars[cursor] == ' ' || chars[cursor] == '\t') {
    cursor += 1
  }
  if cursor < chars.length() && chars[cursor] == ':' {
    cursor += 1
  } else if cursor == start {
    return numbers
  }
  while cursor < chars.length() {
    while cursor < chars.length() &&
          (chars[cursor] == ' ' || chars[cursor] == '\t') {
      cursor += 1
    }
    guard cursor + 1 < chars.length() &&
      chars[cursor] == '#' &&
      chars[cursor + 1] >= '1' &&
      chars[cursor + 1] <= '9' else {
      break
    }
    cursor += 1
    let mut number = 0L
    while cursor < chars.length() && chars[cursor].is_ascii_digit() {
      let digit = (chars[cursor].to_int() - 48).to_int64()
      guard number <= (9223372036854775807L - digit) / 10L else {
        return numbers
      }
      number = number * 10L + digit
      cursor += 1
    }
    if cursor < chars.length() &&
      !chars[cursor].is_whitespace() &&
      ![',', '.', ';', ':', ')', ']', '}', '!', '?'].contains(chars[cursor]) {
      break
    }
    numbers.push(number)
    let end = cursor
    while cursor < chars.length() &&
          (chars[cursor] == ' ' || chars[cursor] == '\t') {
      cursor += 1
    }
    if cursor < chars.length() && chars[cursor] == ',' {
      cursor += 1
      while cursor < chars.length() &&
            (chars[cursor] == ' ' || chars[cursor] == '\t') {
        cursor += 1
      }
    } else if cursor == end {
      break
    }
    if cursor + 3 < chars.length() &&
      chars[cursor] == 'a' &&
      chars[cursor + 1] == 'n' &&
      chars[cursor + 2] == 'd' &&
      (chars[cursor + 3] == ' ' || chars[cursor + 3] == '\t') {
      cursor += 4
    } else if cursor == end || chars.get(cursor) != Some('#') {
      break
    }
  }
  numbers
}

///|
/// Issue numbers declared by closing keywords in an MR description, in order
/// with duplicates removed. Missing/already closed issues are ignored at merge.
/// Code, quoted lines, escaped text and HTML comments do not declare closures.
pub fn closing_issue_numbers(description : String) -> Array[Int64] {
  let numbers : Array[Int64] = []
  let seen : Map[Int64, Bool] = Map([])
  let mut fence : Char? = None
  let mut fence_length = 0
  let mut inline_ticks = 0
  let mut comment = false
  for line in description.split("\n") {
    let chars = line.to_lower().to_array()
    let mut first = 0
    while first < chars.length() && chars[first] == ' ' {
      first += 1
    }
    if inline_ticks == 0 && !comment && first < chars.length() {
      let marker = chars[first]
      if first < 4 && (marker == '`' || marker == '~') {
        let mut end = first
        while end < chars.length() && chars[end] == marker {
          end += 1
        }
        if end - first >= 3 {
          if fence is None {
            fence = Some(marker)
            fence_length = end - first
            continue
          } else if fence == Some(marker) &&
            end - first >= fence_length &&
            chars[end:].iter().all(ch => ch.is_whitespace()) {
            fence = None
            continue
          }
        }
      }
    }
    if fence is Some(_) ||
      first >= 4 ||
      chars.get(first) == Some('\t') ||
      chars.get(first) == Some('>') {
      continue
    }
    let mut cursor = 0
    while cursor < chars.length() {
      if inline_ticks == 0 &&
        cursor + 3 < chars.length() &&
        chars[cursor] == '<' &&
        chars[cursor + 1] == '!' &&
        chars[cursor + 2] == '-' &&
        chars[cursor + 3] == '-' {
        comment = true
        cursor += 4
        continue
      }
      if comment {
        if cursor + 2 < chars.length() &&
          chars[cursor] == '-' &&
          chars[cursor + 1] == '-' &&
          chars[cursor + 2] == '>' {
          comment = false
          cursor += 3
        } else {
          cursor += 1
        }
        continue
      }
      if chars[cursor] == '`' {
        let start = cursor
        while cursor < chars.length() && chars[cursor] == '`' {
          cursor += 1
        }
        let ticks = cursor - start
        if inline_ticks == 0 {
          inline_ticks = ticks
        } else if inline_ticks == ticks {
          inline_ticks = 0
        }
        continue
      }
      if inline_ticks != 0 {
        cursor += 1
        continue
      }
      if chars[cursor] == '\\' {
        cursor += 2
        continue
      }
      if chars[cursor].is_ascii_alphabetic() {
        let start = cursor
        let word = StringBuilder()
        while cursor < chars.length() && chars[cursor].is_ascii_alphabetic() {
          word.write_char(chars[cursor])
          cursor += 1
        }
        if start > 0 &&
          !chars[start - 1].is_whitespace() &&
          !['(', '[', '{', '"', '\'', ',', ';', ':', '.', '!', '?'].contains(
            chars[start - 1],
          ) {
          continue
        }
        if [
            "close", "closes", "closed", "fix", "fixes", "fixed", "resolve", "resolves",
            "resolved",
          ].contains(word.to_string()) {
          for number in closing_issue_clause(chars, cursor) {
            if !seen.contains(number) {
              seen[number] = true
              numbers.push(number)
            }
          }
        }
      } else {
        cursor += 1
      }
    }
  }
  numbers
}
