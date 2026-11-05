///|
// Invalid names are display-only. Their identity is always derived from bytes.
fn diff_path(bytes : BytesView) -> (String, Bool) {
  (@utf8.decode(bytes), false) catch {
    _ => {
      let display = StringBuilder()
      display.write_char('"')
      for byte in bytes {
        if byte >= 0x20 && byte <= 0x7e && byte != b'"' && byte != b'\\' {
          display.write_char(byte.to_int().unsafe_to_char())
        } else {
          display.write_string("\\x")
          display.write_string(
            @crypto.bytes_to_hex_string(Bytes::from_array([byte])),
          )
        }
      }
      display.write_char('"')
      (display.to_string(), true)
    }
  }
}

///|
fn compare_diff_files(a : DiffFile, b : DiffFile) -> Int32 {
  let ap = if a.new_path.is_empty() { a.old_path } else { a.new_path }
  let bp = if b.new_path.is_empty() { b.old_path } else { b.new_path }
  if ap.has_suffix(".mbti") != bp.has_suffix(".mbti") {
    if ap.has_suffix(".mbti") {
      -1
    } else {
      1
    }
  } else {
    let order = ap.lexical_compare(bp)
    if order == 0 {
      a.id.lexical_compare(b.id)
    } else {
      order
    }
  }
}

///|
// Bound uninterrupted CPU work even for large comparisons. Sorting a whole
// manifest synchronously would prevent the deadline/cancellation from firing.
async fn sort_diff_files(files : Array[DiffFile]) -> Array[DiffFile] {
  let mut chunks : Array[Array[DiffFile]] = []
  for start = 0; start < files.length(); start = start + 256 {
    let end = if start + 256 < files.length() {
      start + 256
    } else {
      files.length()
    }
    let chunk = files[start:end].to_owned()
    chunk.sort_by(compare_diff_files)
    chunks.push(chunk)
    @async.sleep(0)
  }
  while chunks.length() > 1 {
    let merged = []
    for c = 0; c < chunks.length(); c = c + 2 {
      if c + 1 == chunks.length() {
        merged.push(chunks[c])
        continue
      }
      let a = chunks[c]
      let b = chunks[c + 1]
      let out = []
      for i = 0, j = 0; i < a.length() || j < b.length(); {
        if out.length() % 256 == 0 {
          @async.sleep(0)
        }
        if j == b.length() ||
          (i < a.length() && compare_diff_files(a[i], b[j]) <= 0) {
          out.push(a[i])
          continue i + 1, j
        } else {
          out.push(b[j])
          continue i, j + 1
        }
      }
      merged.push(out)
    }
    chunks = merged
  }
  chunks.get(0).unwrap_or([])
}

///|
async fn parse_diff_files(raw : Bytes) -> Array[DiffFile] {
  let fields : Array[BytesView] = []
  let mut start = 0
  for i in 0..<raw.length() {
    if i % 65536 == 0 {
      @async.sleep(0)
    }
    if raw[i] == 0 {
      fields.push(raw[start:i])
      start = i + 1
    }
  }
  guard start == raw.length() else {
    raise DiffFailure("invalid Git file manifest")
  }
  let files : Array[DiffFile] = []
  let mut i = 0
  while i < fields.length() {
    if files.length() % 256 == 0 {
      @async.sleep(0)
    }
    let meta = diff_text(fields[i]).split(" ").map(s => s.to_owned()).collect()
    guard meta.length() == 5 &&
      meta[0].has_prefix(":") &&
      i + 1 < fields.length() else {
      raise DiffFailure("invalid Git file manifest")
    }
    let status = meta[4]
    let old_bytes = fields[i + 1]
    let mut new_bytes = old_bytes
    i += 2
    if status.has_prefix("R") || status.has_prefix("C") {
      guard i < fields.length() else {
        raise DiffFailure("invalid Git rename record")
      }
      new_bytes = fields[i]
      i += 1
    }
    let old_bytes = if status == "A" { b""[:] } else { old_bytes }
    let new_bytes = if status == "D" { b""[:] } else { new_bytes }
    let (old_path, old_error) = diff_path(old_bytes)
    let (new_path, new_error) = diff_path(new_bytes)
    let path_error = if old_error || new_error {
      Some(
        "non-UTF-8 path; structured diff and inline comments are unavailable for this file",
      )
    } else {
      None
    }
    let old_mode = meta[0][1:].to_owned()
    let new_mode = meta[1]
    guard [meta[2], meta[3]].all(id => valid_commit_sha(id)) else {
      raise DiffFailure("invalid Git object identity")
    }
    let id = if path_error is Some(_) {
      diff_identity([
        "raw-path-bytes",
        @crypto.bytes_to_hex_string(old_bytes.to_owned()),
        @crypto.bytes_to_hex_string(new_bytes.to_owned()),
        old_mode,
        new_mode,
        meta[2],
        meta[3],
      ])
    } else {
      diff_identity([old_path, new_path, old_mode, new_mode, meta[2], meta[3]])
    }
    files.push({
      id,
      status,
      old_path,
      new_path,
      old_mode,
      new_mode,
      old_blob: meta[2],
      new_blob: meta[3],
      path_error,
    })
  }
  sort_diff_files(files)
}

///|
async fn DiffExecutor::manifest_files(
  self : DiffExecutor,
  git_dir : String,
  base_sha : String,
  head_sha : String,
) -> Array[DiffFile] {
  guard valid_commit_sha(base_sha) && valid_commit_sha(head_sha) else {
    raise @domain.BadRequest(message="fixed comparison SHAs are required")
  }
  let key = "manifest:" +
    diff_identity([@diff_protocol.protocol_version, git_dir, base_sha, head_sha])
  let value = self.compute_cached(key, "manifest", () => {
    let raw = bounded_process(
      "git",
      git_args(git_dir, [
        "diff", "--raw", "-z", "--no-abbrev", "--no-ext-diff", "--no-textconv", "--find-renames",
        base_sha, head_sha, "--",
      ]),
      "",
      16777216,
    )
    self.output_bytes += raw.length().to_int64()
    let files = parse_diff_files(raw)
    // Account for the serialized array without allocating a second full copy.
    let mut size = 2
    for i, file in files {
      if i % 256 == 0 {
        @async.sleep(0)
      }
      size += @utf8.encode(Json(file).stringify()).length() +
        (if i == 0 { 0 } else { 1 })
    }
    (Manifest(files), size)
  })
  guard value is Manifest(files) else {
    raise DiffFailure("invalid diff cache entry")
  }
  files
}

///|
fn manifest_page(
  git_dir : String,
  base_sha : String,
  head_sha : String,
  files : Array[DiffFile],
  page : Int32,
) -> DiffManifest {
  let start = (page - 1) * 100
  {
    protocol: @diff_protocol.protocol_version,
    engine: @diff_protocol.engine_version,
    comparison_id: diff_identity([git_dir, base_sha, head_sha]),
    base_sha,
    head_sha,
    page,
    has_more: files.length() > start + 100,
    files: if start >= files.length() {
      []
    } else {
      let end = if start + 100 < files.length() {
        start + 100
      } else {
        files.length()
      }
      files[start:end].to_owned()
    },
  }
}

///|
pub async fn DiffExecutor::manifest(
  self : DiffExecutor,
  git_dir : String,
  base_sha : String,
  head_sha : String,
  page~ : Int32 = 1,
) -> DiffManifest {
  guard page > 0 && page <= 100000 else {
    raise @domain.BadRequest(message="a positive diff page is required")
  }
  let files = self.manifest_files(git_dir, base_sha, head_sha)
  manifest_page(git_dir, base_sha, head_sha, files, page)
}

///|
// The caller supplies an already authorized, stored anchor. No caller-supplied
// path is interpreted as a Git object or used to read a source file.
pub async fn DiffExecutor::locate_anchor(
  self : DiffExecutor,
  git_dir : String,
  anchor : DiffAnchor,
) -> (DiffManifest, String)? {
  let path = if anchor.side == "old" {
    anchor.old_path
  } else {
    anchor.new_path
  }
  guard !path.is_empty() && (anchor.side == "old" || anchor.side == "new") else {
    return None
  }
  let files = self.manifest_files(git_dir, anchor.base_sha, anchor.head_sha)
  for i, file in files {
    if i % 256 == 0 {
      @async.sleep(0)
    }
    if file.path_error is None &&
      file.old_path == anchor.old_path &&
      file.new_path == anchor.new_path {
      return Some(
        (
          manifest_page(
            git_dir,
            anchor.base_sha,
            anchor.head_sha,
            files,
            i / 100 + 1,
          ),
          file.id,
        ),
      )
    }
  }
  None
}
