///|
#derive(ToJson, FromJson)
pub struct DiffFile {
  id : String
  status : String
  old_path : String
  new_path : String
  old_mode : String
  new_mode : String
  old_blob : String
  new_blob : String
  path_error : String?
}

///|
pub extend DiffFile with ToJson::{to_json}

///|
pub extend DiffFile with @json.FromJson::{from_json}

///|
#derive(ToJson, FromJson)
pub struct DiffManifest {
  protocol : String
  engine : String
  comparison_id : String
  base_sha : String
  head_sha : String
  page : Int32
  has_more : Bool
  files : Array[DiffFile]
}

///|
pub extend DiffManifest with ToJson::{to_json}

///|
pub extend DiffManifest with @json.FromJson::{from_json}

///|
#derive(FromJson)
pub struct FileDiff {
  protocol : String
  engine : String
  comparison_id : String
  document_id : String
  file : DiffFile
  options : @diff_protocol.Options
  document : @diff_protocol.Document?
  error : String?
}

///|
// Explicit null distinguishes unavailable source from a missing response field.
pub impl ToJson for FileDiff with fn to_json(self) {
  {
    "protocol": self.protocol,
    "engine": self.engine,
    "comparison_id": self.comparison_id,
    "document_id": self.document_id,
    "file": self.file.to_json(),
    "options": self.options.to_json(),
    "document": self.document.map(doc => doc.to_json()).unwrap_or(Json::null()),
    "error": self.error.map(message => Json(message)).unwrap_or(Json::null()),
  }
}

///|
pub extend FileDiff with ToJson::{to_json}

///|
pub extend FileDiff with @json.FromJson::{from_json}

///|
fn diff_identity(value : Json) -> String {
  @crypto.bytes_to_hex_string(@crypto.sha256(@utf8.encode(value.stringify())))
}

///|
pub fn diff_options(
  mode~ : String = "lexical",
  ignore_comments~ : String = "true",
  ignore_tests~ : String = "true",
) -> @diff_protocol.Options raise {
  guard ["lexical", "ast", "line"].contains(mode) &&
    ["true", "false"].contains(ignore_comments) &&
    ["true", "false"].contains(ignore_tests) else {
    raise @domain.BadRequest(message="invalid structured diff options")
  }
  @diff_protocol.Options::new(
    mode~,
    ignore_comments=ignore_comments == "true",
    ignore_tests=ignore_tests == "true",
  )
}

///|
async fn diff_blob(git_dir : String, blob : String, mode : String) -> String? {
  if mode == "000000" {
    return None
  }
  guard mode != "160000" else { raise DiffFailure("submodule") }
  let source = diff_text(
    bounded_process(
      "git",
      git_args(git_dir, ["cat-file", "blob", blob]),
      "",
      @diff_protocol.source_limit,
    ),
  )
  guard !source.contains("\u{0000}") else { raise DiffFailure("binary file") }
  Some(source)
}

///|
pub async fn DiffExecutor::file(
  self : DiffExecutor,
  git_dir : String,
  manifest : DiffManifest,
  file_id : String,
  options : @diff_protocol.Options,
) -> FileDiff {
  guard manifest.files.iter().find_first(f => f.id == file_id) is Some(file) else {
    raise @domain.NotFound(message="file is not on this comparison page")
  }
  let options = if options.mode == "line" ||
    !(file.old_path.has_suffix(".mbt") || file.new_path.has_suffix(".mbt")) {
    @diff_protocol.Options::new(
      mode="line",
      ignore_comments=false,
      ignore_tests=false,
    )
  } else {
    options
  }
  let document_id = diff_identity([
    @diff_protocol.protocol_version,
    @diff_protocol.engine_version,
    manifest.comparison_id,
    file.id,
    options.to_json(),
  ])
  let (document, error) = if file.path_error is Some(message) {
    (None, Some(message))
  } else {
    try {
      let document = self.execute(document_id, () => {
        let old_source = diff_blob(git_dir, file.old_blob, file.old_mode)
        let new_source = diff_blob(git_dir, file.new_blob, file.new_mode)
        {
          protocol: @diff_protocol.protocol_version,
          old_path: file.old_path,
          new_path: file.new_path,
          old_source,
          new_source,
          options,
        }
      })
      (Some(document), None)
    } catch {
      DiffFailure(message) => (None, Some(message))
      _ => (None, Some("diff failed; retry or select line mode"))
    }
  }
  {
    protocol: @diff_protocol.protocol_version,
    engine: @diff_protocol.engine_version,
    comparison_id: manifest.comparison_id,
    document_id,
    file,
    options,
    document,
    error,
  }
}

///|
// Caller must authorize both before and after this operation, including cache hits.
pub async fn DiffExecutor::structured(
  self : DiffExecutor,
  git_dir : String,
  base_sha : String,
  head_sha : String,
  options : @diff_protocol.Options,
  page~ : Int32 = 1,
  file_id~ : String = "",
) -> Json {
  let manifest = self.manifest(git_dir, base_sha, head_sha, page~)
  if file_id.is_empty() {
    Json(manifest)
  } else {
    Json(self.file(git_dir, manifest, file_id, options))
  }
}

///|
pub async fn commit_comparison(
  git_dir : String,
  commit : String,
) -> (String, String) {
  guard valid_commit_sha(commit) else {
    raise @domain.BadRequest(message="full commit SHA required")
  }
  let parents = merge_git(git_dir, [
      "rev-list", "--parents", "--no-walk", commit, "--",
    ])
    .trim()
    .to_owned()
    .split(" ")
    .map(s => s.to_owned())
    .collect()
  guard !parents.is_empty() && parents[0] == commit else {
    raise @domain.NotFound(message="commit not found")
  }
  let base = if parents.length() > 1 {
    parents[1]
  } else {
    merge_git(git_dir, ["hash-object", "-t", "tree", "--stdin"])
    .trim()
    .to_owned()
  }
  (base, commit)
}
