///|
pub struct DiffAnchor {
  commit_sha : String
  base_sha : String
  head_sha : String
  old_path : String
  new_path : String
  side : String
  start_line : Int64
  end_line : Int64
  context : String
} derive(ToJson, FromJson)

///|
pub extend DiffAnchor with ToJson::{to_json}

///|
pub extend DiffAnchor with @json.FromJson::{from_json}

///|
fn diff_hunk_start(value : String) -> Int64 raise {
  let first = value.split(",").next().unwrap_or("")
  @string.parse_int64(first) catch {
    _ => raise @domain.BadRequest(message="unsupported diff hunk")
  }
}

///|
pub async fn validate_diff_anchor(
  git_dir : String,
  revision : Revision,
  commit : String?,
  path : String,
  side : String,
  start_line : Int64,
  end_line : Int64,
) -> DiffAnchor {
  guard (side == "old" || side == "new") &&
    start_line > 0L &&
    end_line >= start_line &&
    end_line - start_line < 100L &&
    end_line <= 1000000000L &&
    !path.is_empty() &&
    path.length() <= 4096 &&
    !path.contains("\u{0000}") else {
    raise @domain.BadRequest(
      message="select 1–100 consecutive lines on one diff side",
    )
  }
  let comparison = revision_comparison(git_dir, revision, commit)
  let names = merge_git(git_dir, [
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--name-status",
    "-z",
    "--find-renames",
    comparison.base_sha,
    comparison.head_sha,
    "--",
  ])
  let fields = names.split("\u{0000}").map(value => value.to_owned()).collect()
  let mut index = 0
  let mut old_path = ""
  let mut new_path = ""
  let mut found = false
  let mut file_index = 0
  while index + 1 < fields.length() {
    let status = fields[index]
    let old = fields[index + 1]
    let mut new = old
    index = index + 2
    if status.has_prefix("R") || status.has_prefix("C") {
      guard index < fields.length() else {
        raise @domain.BadRequest(message="unsupported diff paths")
      }
      new = fields[index]
      index = index + 1
    }
    let old = if status == "A" { "" } else { old }
    let new = if status == "D" { "" } else { new }
    if (if side == "old" { old } else { new }) == path {
      old_path = old
      new_path = new
      found = true
      break
    }
    file_index = file_index + 1
  }
  guard found else {
    raise @domain.BadRequest(
      message="file is not present on the selected diff side",
    )
  }
  let patch = merge_git(git_dir, [
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--find-renames",
    "--unified=3",
    comparison.base_sha,
    comparison.head_sha,
    "--",
  ])
  let files = patch
    .split("\ndiff --git ")
    .map(value => value.to_owned())
    .collect()
  guard file_index < files.length() else {
    raise @domain.BadRequest(message="unsupported diff layout")
  }
  let patch = files[file_index]
  let context = anchor_context(patch, side, start_line, end_line)
  {
    commit_sha: commit.unwrap_or(""),
    base_sha: comparison.base_sha,
    head_sha: comparison.head_sha,
    old_path,
    new_path,
    side,
    start_line,
    end_line,
    context,
  }
}

///|
fn anchor_context(
  patch : String,
  side : String,
  start_line : Int64,
  end_line : Int64,
) -> String raise {
  let mut old = 0L
  let mut new = 0L
  let mut hunk = false
  let mut expected = start_line
  let mut selected_hunk = 0
  let mut hunk_index = 0
  let snippet = StringBuilder()
  for line in patch.split("\n") {
    if line.has_prefix("@@ ") {
      let parts = line.split(" ").map(value => value.to_owned()).collect()
      guard parts.length() >= 3 else {
        raise @domain.BadRequest(message="unsupported diff hunk")
      }
      old = diff_hunk_start(parts[1][1:].to_owned())
      new = diff_hunk_start(parts[2][1:].to_owned())
      hunk = true
      hunk_index = hunk_index + 1
    } else if line.has_prefix("diff --git ") {
      hunk = false
    } else if hunk &&
      (line.has_prefix(" ") || line.has_prefix("+") || line.has_prefix("-")) {
      let on_side = if side == "old" {
        !line.has_prefix("+")
      } else {
        !line.has_prefix("-")
      }
      let number = if side == "old" { old } else { new }
      if on_side && number >= start_line && number <= end_line {
        guard number == expected &&
          (selected_hunk == 0 || selected_hunk == hunk_index) else {
          raise @domain.BadRequest(
            message="range must stay within one displayed diff hunk",
          )
        }
        selected_hunk = hunk_index
        expected = expected + 1L
        snippet.write_string("\{number}: ")
        for ch in line[1:].iter().take(120) {
          snippet.write_char(ch)
        }
        if line.length() > 121 {
          snippet.write_string("…")
        }
        snippet.write_char('\n')
      }
      if !line.has_prefix("+") {
        old = old + 1L
      }
      if !line.has_prefix("-") {
        new = new + 1L
      }
    }
  }
  guard expected == end_line + 1L else {
    raise @domain.BadRequest(
      message="line range is not present in the displayed text diff",
    )
  }
  snippet.to_string()
}
