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
// Locate prose/fence content inside list items without interpreting quoted or
// indented code as directives. A fence may close at its list indentation.
fn closing_markdown_content_start(
  chars : Array[Char],
  indent_limit~ : Int32 = 3,
  strip_lists~ : Bool = true,
) -> Int32? {
  let mut cursor = 0
  while cursor < chars.length() && chars[cursor] == ' ' {
    cursor += 1
  }
  if cursor > indent_limit || chars.get(cursor) == Some('\t') {
    return None
  }
  while strip_lists && cursor < chars.length() {
    if chars[cursor] == '>' {
      return None
    }
    let mut end = cursor
    if ['-', '*', '+'].contains(chars[cursor]) {
      end += 1
    } else {
      while end < chars.length() &&
            chars[end].is_ascii_digit() &&
            end - cursor < 9 {
        end += 1
      }
      if end == cursor || ![Some('.'), Some(')')].contains(chars.get(end)) {
        break
      }
      end += 1
    }
    if ![Some(' '), Some('\t')].contains(chars.get(end)) {
      break
    }
    cursor = end + 1
    while cursor < chars.length() &&
          (chars[cursor] == ' ' || chars[cursor] == '\t') {
      cursor += 1
    }
  }
  Some(cursor)
}

///|
// Only paired backtick runs form code spans. Do not let an unmatched literal
// backtick suppress later directives, or pair across Markdown block boundaries.
fn closing_code_span_end(
  lines : Array[Array[Char]],
  row : Int32,
  start : Int32,
  ticks : Int32,
) -> (Int32, Int32)? {
  for line = row; line < lines.length(); line = line + 1 {
    let chars = lines[line]
    let mut cursor = if line == row { start } else { 0 }
    if line != row {
      let mut first = 0
      while first < chars.length() && chars[first] == ' ' {
        first += 1
      }
      if first == chars.length() ||
        closing_markdown_content_start(chars) != Some(first) {
        return None
      }
      let mut end = first
      while end < chars.length() && chars[end] == '#' {
        end += 1
      }
      if end > first && end - first <= 6 && chars.get(end) == Some(' ') {
        return None
      }
      if ['`', '~', '-'].contains(chars[first]) {
        end = first
        while end < chars.length() && chars[end] == chars[first] {
          end += 1
        }
        if end - first >= 3 {
          return None
        }
      }
    }
    while cursor < chars.length() {
      if chars[cursor] == '`' {
        let begin = cursor
        while cursor < chars.length() && chars[cursor] == '`' {
          cursor += 1
        }
        if cursor - begin == ticks {
          return Some((line, cursor))
        }
      } else {
        cursor += 1
      }
    }
  }
  None
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
  let mut fence_indent = 0
  let mut inline_end : (Int32, Int32)? = None
  let mut comment = false
  let lines = description
    .split("\n")
    .map(line => line.trim_end(chars="\r").to_lower().to_array())
    .collect()
  for row, chars in lines {
    let mut cursor = 0
    if inline_end is Some((line, end)) {
      if row < line {
        continue
      }
      cursor = end
      inline_end = None
    }
    let content = closing_markdown_content_start(
      chars,
      indent_limit=if fence is Some(_) { fence_indent + 3 } else { 3 },
      strip_lists=fence is None,
    )
    if cursor == 0 &&
      !comment &&
      content is Some(first) &&
      first < chars.length() {
      let marker = chars[first]
      if marker == '`' || marker == '~' {
        let mut end = first
        while end < chars.length() && chars[end] == marker {
          end += 1
        }
        if end - first >= 3 {
          if fence is None {
            fence = Some(marker)
            fence_length = end - first
            fence_indent = first
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
    if fence is Some(_) {
      continue
    }
    while cursor < chars.length() {
      if !comment && content is None {
        break
      }
      if !comment &&
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
      if chars[cursor] == '\\' {
        cursor += 2
        continue
      }
      if chars[cursor] == '`' {
        let start = cursor
        while cursor < chars.length() && chars[cursor] == '`' {
          cursor += 1
        }
        let ticks = cursor - start
        if closing_code_span_end(lines, row, cursor, ticks) is Some((line, end)) {
          if line == row {
            cursor = end
          } else {
            inline_end = Some((line, end))
            break
          }
        }
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
