///|
pub(all) struct DiffSelection {
  document_id : String
  file_id : String
  hunk_id : String
  page : Int32
  options : @diff_protocol.Options
}

///|
pub async fn DiffExecutor::validate_anchor(
  self : DiffExecutor,
  git_dir : String,
  revision : Revision,
  commit : String?,
  selection : DiffSelection,
  path : String,
  side : String,
  start_line : Int64,
  end_line : Int64,
) -> DiffAnchor {
  guard (side == "old" || side == "new") &&
    start_line > 0L &&
    end_line >= start_line &&
    end_line - start_line < 100L &&
    end_line <= 1000000000L else {
    raise @domain.BadRequest(
      message="select 1–100 consecutive lines on one diff side",
    )
  }
  let comparison = revision_comparison(git_dir, revision, commit)
  let manifest = self.manifest(
    git_dir,
    comparison.base_sha,
    comparison.head_sha,
    page=selection.page,
  )
  let result = self.file(
    git_dir,
    manifest,
    selection.file_id,
    selection.options,
  )
  guard result.document_id == selection.document_id else {
    raise @domain.BadRequest(
      message="diff document changed; refresh this file and keep your draft",
    )
  }
  guard (if side == "old" {
      result.file.old_path
    } else {
      result.file.new_path
    }) ==
    path &&
    !path.is_empty() else {
    raise @domain.BadRequest(
      message="file is not present on the selected diff side",
    )
  }
  guard result.document is Some(document) else {
    raise @domain.BadRequest(
      message="diff unavailable; retry or select line mode",
    )
  }
  let snippet = StringBuilder()
  let mut found = false
  for section in document.sections {
    for hunk in section.hunks {
      if hunk.id == selection.hunk_id {
        let mut expected = start_line
        for row in hunk.rows {
          let selected = if side == "old" { row.old } else { row.new }
          if selected is Some(line) &&
            line.number.to_int64() >= start_line &&
            line.number.to_int64() <= end_line {
            guard line.number.to_int64() == expected else {
              raise @domain.BadRequest(
                message="range must stay within one displayed diff hunk",
              )
            }
            expected += 1L
            let text = line.segments.iter().map(s => s.text).collect().join("")
            snippet.write_string("\{line.number}: ")
            for ch in text.iter().take(120) {
              snippet.write_char(ch)
            }
            if text.length() > 120 {
              snippet.write_string("…")
            }
            snippet.write_char('\n')
          }
        }
        found = expected == end_line + 1L
      }
    }
  }
  guard found else {
    raise @domain.BadRequest(
      message="range must stay within one displayed diff hunk",
    )
  }
  {
    commit_sha: commit.unwrap_or(""),
    base_sha: comparison.base_sha,
    head_sha: comparison.head_sha,
    old_path: result.file.old_path,
    new_path: result.file.new_path,
    side,
    start_line,
    end_line,
    context: snippet.to_string(),
  }
}
