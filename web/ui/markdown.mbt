///|
fn markdown_escape(value : String) -> String {
  value
  .replace_all(old="&", new="&amp;")
  .replace_all(old="<", new="&lt;")
  .replace_all(old=">", new="&gt;")
  .replace_all(old="\"", new="&quot;")
  .replace_all(old="'", new="&#39;")
}

///|
fn markdown_link(value : String) -> Bool {
  !value.is_empty() &&
  value.iter().all(ch => ch.to_int() > 32 && ch.to_int() != 127) &&
  !value.contains("\\") &&
  (
    value.has_prefix("https://") ||
    value.has_prefix("http://") ||
    value.has_prefix("mailto:") ||
    value.has_prefix("#") ||
    (value.has_prefix("/") && !value.has_prefix("//"))
  )
}

///|
// Only standalone, canonical positive resource numbers become local links.
// Limit to Int64 so the generated destination is accepted by resource routes.
fn markdown_reference_length(value : StringView) -> Int32? {
  guard value.has_prefix("#") || value.has_prefix("!") else { return None }
  guard value.length() > 1 && value[1] >= '1' && value[1] <= '9' else {
    return None
  }
  let mut end = 1
  let mut number = 0L
  while end < value.length() && value[end] >= '0' && value[end] <= '9' {
    let digit = (value[end].to_int() - 48).to_int64()
    guard number <= (9223372036854775807L - digit) / 10L else { return None }
    number = number * 10L + digit
    end += 1
  }
  if end < value.length() {
    let next = value.get_char(end).unwrap()
    if next.is_ascii_alphabetic() ||
      next == '_' ||
      next == '-' ||
      next == '/' ||
      next == '#' ||
      next == '!' {
      return None
    }
  }
  Some(end)
}

///|
fn markdown_inline(
  value : String,
  repo~ : @domain.RepoId? = None,
  depth~ : Int32 = 0,
) -> String {
  if depth >= 4 {
    return markdown_escape(value)
  }
  let out = StringBuilder()
  let mut rest = value[:]
  let mut previous : Char? = None
  while !rest.is_empty() {
    let before = rest
    if rest.has_prefix("`") {
      let mut ticks = 1
      while ticks < rest.length() && rest[ticks] == '`' {
        ticks += 1
      }
      let mut cursor = ticks
      let mut close : Int32? = None
      while cursor < rest.length() {
        if rest[cursor] == '`' {
          let start = cursor
          while cursor < rest.length() && rest[cursor] == '`' {
            cursor += 1
          }
          if cursor - start == ticks {
            close = Some(start)
            break
          }
        } else {
          cursor += 1
        }
      }
      if close is Some(end) {
        out.write_string(
          "<code>" + markdown_escape(rest[ticks:end].to_owned()) + "</code>",
        )
        rest = rest[end + ticks:]
      } else {
        out.write_string(rest[:ticks].to_owned())
        rest = rest[ticks:]
      }
    } else if rest.has_prefix("**") && rest[2:].find("**") is Some(end) {
      out.write_string(
        "<strong>" +
        markdown_inline(rest[2:end + 2].to_owned(), repo~, depth=depth + 1) +
        "</strong>",
      )
      rest = rest[end + 4:]
    } else if rest.has_prefix("![") &&
      rest.find("](") is Some(label_end) &&
      rest[label_end + 2:].find(")") is Some(url_end) &&
      markdown_image_url(rest[label_end + 2:label_end + 2 + url_end].to_owned()) {
      let url = markdown_escape(
        rest[label_end + 2:label_end + 2 + url_end].to_owned(),
      )
      let alt = markdown_escape(rest[2:label_end].to_owned())
      out.write_string(
        "<a href=\"" +
        url +
        "\" target=\"_blank\" rel=\"noopener noreferrer\"><img src=\"" +
        url +
        "\" alt=\"" +
        alt +
        "\" loading=\"lazy\" decoding=\"async\"></a>",
      )
      rest = rest[label_end + 3 + url_end:]
    } else if rest.has_prefix("[") &&
      rest.find("](") is Some(label_end) &&
      rest[label_end + 2:].find(")") is Some(url_end) &&
      markdown_link(rest[label_end + 2:label_end + 2 + url_end].to_owned()) {
      let url = rest[label_end + 2:label_end + 2 + url_end].to_owned()
      out.write_string(
        "<a href=\"" +
        markdown_escape(url) +
        "\" rel=\"nofollow noreferrer\">" +
        markdown_inline(rest[1:label_end].to_owned(), depth=depth + 1) +
        "</a>",
      )
      rest = rest[label_end + 3 + url_end:]
    } else if (rest.length() >= 8 && rest[:8].to_lower() == "https://") ||
      (rest.length() >= 7 && rest[:7].to_lower() == "http://") ||
      (rest.length() >= 7 && rest[:7].to_lower() == "mailto:") {
      let mut end = 0
      for ch in rest.iter() {
        if ch.is_whitespace() {
          break
        }
        end += ch.to_string().length()
      }
      out.write_string(markdown_escape(rest[:end].to_owned()))
      rest = rest[end:]
    } else if rest.has_prefix("\\#") || rest.has_prefix("\\!") {
      out.write_string(rest[1:2].to_owned())
      rest = rest[2:]
    } else if repo is Some(repo) &&
      previous
      .map(ch => {
        ch.is_whitespace() ||
        !ch.is_ascii() ||
        "([{<\"',;:*".contains(ch.to_string())
      })
      .unwrap_or(true) &&
      markdown_reference_length(rest) is Some(end) {
      let kind = if rest.has_prefix("#") { "issues" } else { "merge-requests" }
      out.write_string(
        "<a href=\"" +
        markdown_escape(repo_link(repo)) +
        "/" +
        kind +
        "/" +
        rest[1:end].to_owned() +
        "\" rel=\"nofollow noreferrer\">" +
        rest[:end].to_owned() +
        "</a>",
      )
      rest = rest[end:]
    } else {
      // Consume ordinary text by Unicode code point, never split a surrogate pair.
      let ch = rest.iter().next().unwrap()
      let text = ch.to_string()
      out.write_string(markdown_escape(text))
      rest = rest[text.length():]
    }
    previous = before[:before.length() - rest.length()].iter().last()
  }
  out.to_string()
}

///|
fn markdown_image_url(value : String) -> Bool {
  let parts = value.split("/").collect()
  parts.length() == 5 &&
  parts[0].is_empty() &&
  @domain.valid_name_key(parts[1].to_owned()) &&
  @domain.valid_repo_name(parts[2].to_owned()) &&
  parts[3] == "attachments" &&
  parts[4].length() == 64 &&
  parts[4].iter().all(c => c.is_ascii_digit() || (c >= 'a' && c <= 'f'))
}

///|
// Deliberately bounded Markdown: prose, headings, lists, quotes, fences, links,
// strong and inline code. Raw HTML and arbitrary URL schemes are always text.
pub fn markdown(
  value : String,
  repo~ : @domain.RepoId? = None,
) -> @moonback.Html {
  let out = StringBuilder()
  let paragraph : Array[String] = []
  let mut list = ""
  let mut fenced = false
  for raw in value.split("\n") {
    let line = raw.trim_end(chars="\r").to_owned()
    let trimmed = line.trim().to_owned()
    if trimmed.has_prefix("```") {
      if !paragraph.is_empty() {
        out.write_string(
          "<p>" + markdown_inline(paragraph.join("\n"), repo~) + "</p>",
        )
        paragraph.clear()
      }
      if !list.is_empty() {
        out.write_string("</" + list + ">")
        list = ""
      }
      out.write_string(if fenced { "</code></pre>" } else { "<pre><code>" })
      fenced = !fenced
      continue
    }
    if fenced {
      out.write_string(markdown_escape(line) + "\n")
      continue
    }
    let mut heading = 0
    while heading < trimmed.length() && heading < 6 && trimmed[heading] == '#' {
      heading = heading + 1
    }
    let ordered = trimmed
      .find(". ")
      .filter(index => {
        index > 0 &&
        index <= 9 &&
        trimmed[:index].iter().all(ch => ch.is_ascii_digit())
      })
    let item = if trimmed.has_prefix("- ") || trimmed.has_prefix("* ") {
      Some(("ul", trimmed[2:].to_owned()))
    } else {
      ordered.map(index => ("ol", trimmed[index + 2:].to_owned()))
    }
    let block = trimmed.is_empty() ||
      item is Some(_) ||
      (heading > 0 && trimmed[heading:].has_prefix(" ")) ||
      trimmed.has_prefix("> ") ||
      trimmed == "---"
    if block && !paragraph.is_empty() {
      out.write_string(
        "<p>" + markdown_inline(paragraph.join("\n"), repo~) + "</p>",
      )
      paragraph.clear()
    }
    if item is Some((kind, body)) {
      if kind != list {
        if !list.is_empty() {
          out.write_string("</" + list + ">")
        }
        out.write_string("<" + kind + ">")
        list = kind
      }
      out.write_string("<li>" + markdown_inline(body, repo~) + "</li>")
    } else {
      if !list.is_empty() {
        out.write_string("</" + list + ">")
        list = ""
      }
      if trimmed.is_empty() {
        continue
      }
      if heading > 0 && trimmed[heading:].has_prefix(" ") {
        let tag = "h" + Int32::min(heading + 1, 6).to_string()
        out.write_string(
          "<" +
          tag +
          ">" +
          markdown_inline(trimmed[heading + 1:].to_owned(), repo~) +
          "</" +
          tag +
          ">",
        )
      } else if trimmed.has_prefix("> ") {
        out.write_string(
          "<blockquote><p>" +
          markdown_inline(trimmed[2:].to_owned(), repo~) +
          "</p></blockquote>",
        )
      } else if trimmed == "---" {
        out.write_string("<hr>")
      } else {
        paragraph.push(line)
      }
    }
  }
  if fenced {
    out.write_string("</code></pre>")
  }
  if !list.is_empty() {
    out.write_string("</" + list + ">")
  }
  if !paragraph.is_empty() {
    out.write_string(
      "<p>" + markdown_inline(paragraph.join("\n"), repo~) + "</p>",
    )
  }
  @moonback.Html::raw(out.to_string())
}
