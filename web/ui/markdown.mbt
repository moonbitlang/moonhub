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
// Restrict inline images to repository attachment paths.
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
// Only standalone, canonical positive Int64 values are resource numbers.
fn markdown_reference_length(value : StringView) -> Int32? {
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
  if end < value.length() &&
    value[end] is ('a'..<='z' | 'A'..<='Z' | '_' | '-' | '/' | '#' | '!') {
    None
  } else {
    Some(end)
  }
}

///|
fn markdown_bare_url(value : StringView) -> Bool {
  for scheme in ["https://", "http://", "mailto:"] {
    if value.length() < scheme.length() {
      continue
    }
    let matches = for index in 0..<scheme.length() {
      let actual = value[index].unsafe_to_char()
      if @cmark_char.to_ascii_lower(actual) != scheme[index].unsafe_to_char() {
        break false
      }
    } nobreak {
      true
    }
    if matches {
      return true
    }
  }
  false
}

///|
// Use cmark's source spans to distinguish literal reference markers from
// backslash escapes and entities. Let cmark decode the surrounding text.
fn render_markdown_references(
  ctx : @cmark_renderer.Context,
  text : @cmark.Node[String],
  source : String,
  repo : @domain.RepoId,
) -> Bool {
  guard text.v.contains("#") || text.v.contains("!") else { return false }
  let { first_ccode: first, last_ccode, .. } = text.meta.loc
  let end = last_ccode + 1
  guard first >= 0 && first < end && end <= source.length() else {
    return false
  }
  let decoded = StringBuilder()
  fn write_text(first, end) {
    if first < end {
      ctx.string(
        markdown_escape(
          @cmark_char.utf_16_clean_unesc_unref(
            decoded,
            source,
            first~,
            last=end - 1,
          ),
        ),
      )
    }
  }

  for pos = first, plain_start = first; pos < end; {
    match source[pos] {
      '#' | '!' => {
        let previous = @cmark_char.prev_char(source[:], first=0, before=pos)
        let boundary = previous.is_whitespace() ||
          !previous.is_ascii() ||
          "([{<\"',;:*".contains(previous.to_string()) ||
          (pos == first && (previous == '_' || previous == '>'))
        if boundary &&
          markdown_reference_length(source[pos:end]) is Some(length) {
          write_text(plain_start, pos)
          let kind = if source[pos] == '#' {
            "issues"
          } else {
            "merge-requests"
          }
          let number = source[pos + 1:pos + length].to_owned()
          let url = markdown_escape("\{repo_link(repo)}/\{kind}/\{number}")
          ctx.string(
            "<a href=\"\{url}\" rel=\"nofollow noreferrer\">\{source[pos:pos + length]}</a>",
          )
          continue pos + length, pos + length
        }
      }
      'h' | 'H' | 'm' | 'M' if markdown_bare_url(source[pos:end]) => {
        let mut next = pos
        for ch in source[pos:end] {
          if ch.is_whitespace() {
            break
          }
          next += ch.to_string().length()
        }
        continue next, plain_start
      }
      _ => ()
    }
    continue pos + 1, plain_start
  } nobreak {
    if plain_start == first {
      false
    } else {
      write_text(plain_start, end)
      true
    }
  }
}

///|
fn write_markdown_title(
  ctx : @cmark_renderer.Context,
  title : @cmark.Seq[@cmark.Tight]?,
) -> Unit {
  if title is Some(lines) {
    let title = markdown_escape(
      lines.iter().map(line => line.node.v).join("\n"),
    )
    ctx.string(" title=\"\{title}\"")
  }
}

///|
fn render_markdown_link(
  ctx : @cmark_renderer.Context,
  label : @cmark.Inline,
  url : String,
  title : @cmark.Seq[@cmark.Tight]?,
  in_link_label : Ref[Bool],
) -> Unit raise {
  let was_in_link_label = in_link_label.val
  let linked = !was_in_link_label && markdown_link(url)
  if linked {
    ctx.string(
      "<a href=\"\{markdown_escape(url)}\" rel=\"nofollow noreferrer\"",
    )
    write_markdown_title(ctx, title)
    ctx.char('>')
  }
  in_link_label.val = true
  ctx.inline(label)
  in_link_label.val = was_in_link_label
  if linked {
    ctx.string("</a>")
  }
}

///|
fn markdown_raw_inline(html : @cmark.InlineRawHtml) -> String {
  html.0.iter().map(line => line.node.v).join("\n")
}

///|
fn render_markdown_image(
  ctx : @cmark_renderer.Context,
  image : @cmark.InlineLink,
  in_link_label : Bool,
) -> Unit {
  // Preserve literal angle-bracket text in attachment filenames and labels.
  let label = @cmark.Mapper::new(inline=fn(_, inline) {
      match inline {
        RawHtml({ v: html, meta, }) =>
          Map(Some(Text({ v: markdown_raw_inline(html), meta, })))
        _ => Default
      }
    })
    .map_inline(image.text)
    .unwrap_or(image.text)
  let alt = label
    .to_plain_text(break_on_soft=false)
    .iter()
    .map(line => line.iter().join(""))
    .join("\n")
    |> markdown_escape
  guard image.reference_definition(ctx.doc.defs)
    is Some(LinkDef({ v: { dest: Some({ v: url, .. }), title, .. }, .. })) &&
    markdown_image_url(url) else {
    ctx.string(alt)
    return
  }
  let url = markdown_escape(url)
  if !in_link_label {
    ctx.string(
      "<a href=\"\{url}\" target=\"_blank\" rel=\"noopener noreferrer\">",
    )
  }
  ctx.string(
    "<img src=\"\{url}\" alt=\"\{alt}\" loading=\"lazy\" decoding=\"async\"",
  )
  write_markdown_title(ctx, title)
  ctx.char('>')
  if !in_link_label {
    ctx.string("</a>")
  }
}

///|
fn markdown_html(
  source : String,
  repo~ : @domain.RepoId? = None,
) -> String raise {
  let doc = @cmark.Doc::from_string(source, locs=repo is Some(_))
  let in_link_label = Ref(false)
  let renderer = @cmark_renderer.Renderer::new(
    inline=fn(ctx, inline) raise {
      match inline {
        Text(text) if !in_link_label.val && repo is Some(repo) =>
          return render_markdown_references(ctx, text, source, repo)
        Link({ v: link, .. }) =>
          match link.reference_definition(ctx.doc.defs) {
            Some(LinkDef({ v: def, .. })) =>
              render_markdown_link(
                ctx,
                link.text,
                def.dest.map(node => node.v).unwrap_or(""),
                def.title,
                in_link_label,
              )
            _ => return false
          }
        Autolink({ v: { is_email, link, }, .. }) => {
          let url = if is_email { "mailto:" + link.v } else { link.v }
          render_markdown_link(ctx, Text(link), url, None, in_link_label)
        }
        Image({ v: image, .. }) =>
          render_markdown_image(ctx, image, in_link_label.val)
        RawHtml({ v: html, .. }) =>
          ctx.string(markdown_escape(markdown_raw_inline(html)))
        _ => return false
      }
      true
    },
    block=fn(ctx, block) raise {
      match block {
        // The page title owns h1.
        Heading({ v: { level, inline, .. }, .. }) => {
          let level = Int32::min(level + 1, 6)
          ctx.string("<h\{level}>")
          ctx.inline(inline)
          ctx.string("</h\{level}>\n")
        }
        HtmlBlock({ v: HtmlBlock(lines), .. }) => {
          let text = markdown_escape(
            lines.iter().map(line => line.v).join("\n"),
          )
          ctx.string("<p>\{text}</p>\n")
        }
        _ => return false
      }
      true
    },
  )
  @cmark_html.renderer(safe=true).compose(renderer).doc_to_string(doc)
}

///|
pub fn markdown(
  value : String,
  repo~ : @domain.RepoId? = None,
) -> @moonback.Html {
  let html = markdown_html(value, repo~) catch {
    _ => return @moonback.Html::escape(value)
  }
  @moonback.Html::raw(html)
}
