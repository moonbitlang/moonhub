///|
fn diff_option_query(options : @diff_protocol.Options) -> String {
  "&mode=\{options.mode}&ignore_comments=\{(options.ignore_comments).to_string()}&ignore_tests=\{(options.ignore_tests).to_string()}"
}

///|
pub fn render_diff_document(result : @gitops.FileDiff) -> @moonback.Html {
  Html(b => {
    b <+
      "<h3>\{result.file.old_path} → \{result.file.new_path}</h3><p>\{result.file.status} · mode \{result.file.old_mode} → \{result.file.new_mode}</p>"
    if result.error is Some(error) {
      b <+ "<p role=\"alert\">\{error}</p>"
    }
    if result.document is Some(document) {
      b <+ "<p>\{document.status} · \{document.options.mode}</p>"
      if document.old_eol != document.new_eol ||
        document.old_final_newline != document.new_final_newline {
        b <+
          "<p>Line endings: \{document.old_eol} → \{document.new_eol}. Final newline: \{(document.old_final_newline.unwrap_or(false)).to_string()} → \{(document.new_final_newline.unwrap_or(false)).to_string()}.</p>"
      }
      if document.ignore_reason is Some(reason) {
        b <+
          "<p>Filtered: \{reason}. Disable filters to see the original content.</p>"
      }
      if document.reordered {
        b <+
          "<p>Declaration order changed. Old: \{document.old_order.map(i => i.to_string()).join(" → ")}. New: \{document.new_order.map(i => i.to_string()).join(" → ")}.</p>"
      }
      for section in document.sections {
        if section.hunks.is_empty() && section.fallbacks.is_empty() {
          continue
        }
        b <+
          "<details open><summary>\{section.kind}: \{section.old_context.unwrap_or("∅")} → \{section.new_context.unwrap_or("∅")}</summary>"
        for reason in section.fallbacks {
          b <+ "<p>Fallback: \{reason}</p>"
        }
        for hunk in section.hunks {
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
        b <+ "</details>"
      }
    }
  })
}

///|
pub fn render_structured_diff(
  manifest : @gitops.DiffManifest,
  selected : @gitops.FileDiff?,
  options : @diff_protocol.Options,
  endpoint : String,
  page_url : String,
) -> @moonback.Html {
  let query = diff_option_query(options)
  Html(b => {
    b <+
      "<moonhub-structured-diff id=\"diff-code\" data-endpoint=\"\{endpoint}\" data-manifest=\"\{Json(manifest).stringify()}\" data-options=\"\{Json(options).stringify()}\" data-selected=\"\{selected.map(result => Json(result).stringify()).unwrap_or("")}\"><div data-diff-fallback><nav aria-label=\"Diff options\">"
    for mode in ["lexical", "ast", "line"] {
      b <+
        "<a href=\"\{page_url}&amp;mode=\{mode}&amp;ignore_comments=\{(options.ignore_comments).to_string()}&amp;ignore_tests=\{(options.ignore_tests).to_string()}\">\{mode}</a> "
    }
    b <+
      "<a href=\"\{page_url}&amp;mode=\{options.mode}&amp;ignore_comments=\{(!options.ignore_comments).to_string()}&amp;ignore_tests=\{(options.ignore_tests).to_string()}\">Ignore comments: \{(options.ignore_comments).to_string()}</a> <a href=\"\{page_url}&amp;mode=\{options.mode}&amp;ignore_comments=\{(options.ignore_comments).to_string()}&amp;ignore_tests=\{(!options.ignore_tests).to_string()}\">Ignore tests: \{(options.ignore_tests).to_string()}</a></nav><ul>"
    for file in manifest.files {
      b <+
        "<li><a href=\"\{page_url}&amp;file_id=\{file.id}&amp;page=\{manifest.page.to_string()}\{query}#diff-code\">\{file.status}: \{if file.new_path.is_empty() { file.old_path } else { file.new_path }}</a> · \{file.old_mode} → \{file.new_mode}"
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
    b <+ "</div></moonhub-structured-diff>"
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
  })
}
