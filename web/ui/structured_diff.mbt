///|
fn diff_option_query(options : @diff_protocol.Options) -> String {
  "&mode=\{options.mode}&ignore_comments=\{(options.ignore_comments).to_string()}&ignore_tests=\{(options.ignore_tests).to_string()}"
}

///|
pub fn render_diff_document(result : @gitops.FileDiff) -> @moonback.Html {
  let file_side = match result.file.status {
    "A" => Some("new")
    "D" => Some("old")
    _ => None
  }
  Html(b => {
    b <+ "<section class=\"structured-diff wrap\">"
    if file_side is Some(side) {
      b <+
        "<h3>\{if side == "new" { result.file.new_path } else { result.file.old_path }}</h3>"
    } else {
      b <+
        "<h3>\{if result.file.old_path == result.file.new_path { result.file.new_path } else { result.file.old_path + " → " + result.file.new_path }}</h3>"
      if result.file.old_mode != result.file.new_mode {
        b <+ "<p>Mode: \{result.file.old_mode} → \{result.file.new_mode}</p>"
      }
    }
    if result.error is Some(error) {
      b <+ "<p role=\"alert\">\{error}</p>"
    }
    if result.document is Some(document) {
      if file_side is None {
        b <+ "<p>\{document.status} · \{document.options.mode}</p>"
      }
      if file_side is None &&
        (
          document.old_eol != document.new_eol ||
          document.old_final_newline != document.new_final_newline
        ) {
        b <+
          "<p>Line endings: \{document.old_eol} → \{document.new_eol}. Final newline: \{(document.old_final_newline.unwrap_or(false)).to_string()} → \{(document.new_final_newline.unwrap_or(false)).to_string()}.</p>"
      }
      if document.ignore_reason is Some(reason) {
        b <+
          "<p>Filtered: \{reason}. Disable filters to see the original content.</p>"
      }
      if file_side is None && document.reordered {
        b <+
          "<p>Declaration order changed. Old: \{document.old_order.map(i => i.to_string()).join(" → ")}. New: \{document.new_order.map(i => i.to_string()).join(" → ")}.</p>"
      }
      for section in document.sections {
        if section.hunks.is_empty() && section.fallbacks.is_empty() {
          continue
        }
        let side = match (file_side, section.kind) {
          (Some(side), _) => Some(side)
          (None, "inserted") => Some("new")
          (None, "deleted") => Some("old")
          _ => None
        }
        if side is None {
          b <+
            "<details open><summary>\{section.old_context.unwrap_or(section.new_context.unwrap_or("Changes"))}\{if section.old_context is Some(old) && section.new_context is Some(new) && old != new { " → " + new } else { "" }}</summary>"
          for reason in section.fallbacks {
            b <+ "<p>Fallback: \{reason}</p>"
          }
        }
        for hunk in section.hunks {
          if side is Some(side) {
            b <+
              "<div class=\"structured-hunk\" data-hunk=\"\{hunk.id}\"><table class=\"single-side \{side}\"><tbody>"
            for row in hunk.rows {
              let line = if side == "old" { row.old } else { row.new }
              if line is Some(line) {
                b <+
                  "<tr><td class=\"line-number\">\{line.number.to_string()}</td><td class=\"diff-source\"><code>\{line.segments.map(s => s.text).join("")}</code></td></tr>"
              }
            }
            b <+ "</tbody></table></div>"
          } else {
            b <+ "<pre data-hunk=\"\{hunk.id}\">"
            for row in hunk.rows {
              if row.old is Some(line) {
                b <+
                  "old \{line.number.to_string()}: \{line.segments.map(s => s.text).join("")}\n"
              }
              if row.new is Some(line) {
                b <+
                  "new \{line.number.to_string()}: \{line.segments.map(s => s.text).join("")}\n"
              }
            }
            b <+ "</pre>"
          }
        }
        if side is None {
          b <+ "</details>"
        }
      }
    }
    b <+ "</section>"
  })
}

///|
pub fn render_diff_options(
  options : @diff_protocol.Options,
  view_url : String,
) -> @moonback.Html {
  Html(b => {
    b <+ "<nav aria-label=\"Diff options\">"
    for mode in ["lexical", "ast", "line"] {
      b <+
        "<a href=\"\{view_url}&amp;mode=\{mode}&amp;ignore_comments=\{(options.ignore_comments).to_string()}&amp;ignore_tests=\{(options.ignore_tests).to_string()}#diff-code\">\{mode}</a> "
    }
    b <+
      "<a href=\"\{view_url}&amp;mode=\{options.mode}&amp;ignore_comments=\{(!options.ignore_comments).to_string()}&amp;ignore_tests=\{(options.ignore_tests).to_string()}#diff-code\">Ignore comments: \{(options.ignore_comments).to_string()}</a> <a href=\"\{view_url}&amp;mode=\{options.mode}&amp;ignore_comments=\{(options.ignore_comments).to_string()}&amp;ignore_tests=\{(!options.ignore_tests).to_string()}#diff-code\">Ignore tests: \{(options.ignore_tests).to_string()}</a></nav>"
  })
}

///|
// Both URLs pin the comparison and omit comparison options and fragments.
// view_url retains the current page/file/code; page_url omits those locations.
pub fn render_structured_diff(
  manifest : @gitops.DiffManifest,
  selected : @gitops.FileDiff?,
  options : @diff_protocol.Options,
  endpoint : String,
  page_url : String,
  view_url~ : String,
  toolbar_target~ : String = "",
) -> @moonback.Html {
  let query = diff_option_query(options)
  Html(b => {
    b <+
      "<moonhub-structured-diff id=\"diff-code\" data-toolbar-target=\"\{toolbar_target}\" data-endpoint=\"\{endpoint}\" data-view-url=\"\{view_url}\" data-page-url=\"\{page_url}\" data-manifest=\"\{Json(manifest).stringify()}\" data-options=\"\{Json(options).stringify()}\" data-selected=\"\{selected.map(result => Json(result).stringify()).unwrap_or("")}\"><div data-diff-fallback>"
    if toolbar_target.is_empty() {
      b <+ "\{render_diff_options(options, view_url)}"
    }
    b <+ "<ul>"
    for file in manifest.files {
      let single = file.status == "A" || file.status == "D"
      b <+
        "<li><a href=\"\{page_url}&amp;file_id=\{file.id}&amp;page=\{manifest.page.to_string()}\{query}#diff-code\">\{if single { "" } else { file.status + ": " }}\{if file.new_path.is_empty() { file.old_path } else { file.new_path }}</a>"
      if !single && file.old_mode != file.new_mode {
        b <+ " · Mode: \{file.old_mode} → \{file.new_mode}"
      }
      if file.path_error is Some(error) {
        b <+ "<p role=\"alert\">\{error}</p>"
      }
      b <+ "</li>"
    }
    b <+ "</ul>"
    if manifest.files.is_empty() {
      b <+ "<p>No file changes in this comparison.</p>"
    }
    if selected is Some(result) {
      b <+ "\{render_diff_document(result)}"
    }
    if manifest.page > 1 || manifest.has_more {
      b <+ "<nav aria-label=\"File pages\">"
      if manifest.page > 1 {
        b <+
          "<a href=\"\{page_url}&amp;page=\{(manifest.page - 1).to_string()}\{query}\">Previous files</a> "
      }
      if manifest.has_more {
        b <+
          "<a href=\"\{page_url}&amp;page=\{(manifest.page + 1).to_string()}\{query}\">Next files</a>"
      }
      b <+ "</nav>"
    }
    b <+ "</div></moonhub-structured-diff>"
  })
}
