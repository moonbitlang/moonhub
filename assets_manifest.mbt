///|
let custom_elements_manifest_entry : String = "src/custom-elements.tsx"

///|
fn asset_url(file : String) -> String? {
  guard file != "" && !file.has_prefix("/") && !file.contains("..") else {
    return None
  }
  Some("/\{public_assets_owner}/\{file}")
}

///|
async fn vite_manifest_asset(assets_root : String, entry : String) -> String? {
  try {
    let text = @fs.read_file(
      asset_join_path(assets_root, ".vite/manifest.json"),
    ).text()
    let manifest = @json.parse(text)
    match manifest {
      Object(entries) =>
        match entries.get(entry) {
          Some(Object(entry_fields)) =>
            match entry_fields.get("file") {
              Some(String(file)) => asset_url(file)
              _ => None
            }
          _ => None
        }
      _ => None
    }
  } catch {
    _ => None
  }
}

///|
async fn custom_elements_asset_url(assets_root : String) -> String {
  match vite_manifest_asset(assets_root, custom_elements_manifest_entry) {
    Some(url) => url
    None =>
      abort(
        "missing Vite manifest entry \{custom_elements_manifest_entry} in \{asset_join_path(assets_root, ".vite/manifest.json")}",
      )
  }
}

///|
async fn custom_elements_head(assets_root : String) -> @moonback.Html {
  let url = custom_elements_asset_url(assets_root)
  let raw =
    $|<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=M+PLUS+Code+Latin:wght@400;500;700&amp;display=swap"><link rel="modulepreload" href="\{url}"><script type="module" blocking="render" fetchpriority="high" src="\{url}"></script>
  @moonback.Html::raw(raw)
}
