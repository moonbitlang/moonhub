///|
pub async fn load_entry_to_asset_path_map(
  assets_root : String,
) -> Map[String, String] {
  let map = Map([])

  try {
    let text = @fs.read_file(
      asset_join_path(assets_root, ".vite/manifest.json"),
    ).text()
    let manifest = @json.parse(text)
    guard manifest is Object(entries) else { () }
    for entry in entries {
      let (key, value) = entry
      guard value is Object({ "isEntry": true, "file": String(path), .. }) else {
        ()
      }
      if asset_url(path) is Some(url) {
        map[key] = url
      }
    }
  } catch {
    _ => ()
  }
  map
}

///|
fn asset_url(file : String) -> String? {
  guard file != "" && !file.has_prefix("/") && !file.contains("..") else {
    return None
  }
  Some("/\{@domain.PUBLIC_ASSETS_OWNER}/\{file}")
}

///|
pub fn vite_manifest_entry_path(
  entry_to_asset_path_map : Map[String, String],
  entry : String,
) -> String {
  match entry_to_asset_path_map.get(entry) {
    Some(path) => path
    None => abort("missing Vite manifest entry \{entry}")
  }
}

///|
fn custom_elements_tsx_asset_path(
  entry_to_asset_path_map : Map[String, String],
) -> String {
  vite_manifest_entry_path(entry_to_asset_path_map, "src/custom-elements.tsx")
}

///|
fn app_styles_css_asset_path(
  entry_to_asset_path_map : Map[String, String],
) -> String {
  vite_manifest_entry_path(entry_to_asset_path_map, "src/app.css")
}

///|
pub fn app_styles_head(
  entry_to_asset_path_map : Map[String, String],
) -> @moonback.Html {
  let url = app_styles_css_asset_path(entry_to_asset_path_map)
  @moonback.Html::raw("<link rel=\"stylesheet\" href=\"\{url}\">")
}

///|
fn custom_elements_head(
  entry_to_asset_path_map : Map[String, String],
) -> @moonback.Html {
  let url = custom_elements_tsx_asset_path(entry_to_asset_path_map)
  let raw =
    $|<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=M+PLUS+Code+Latin:wght@400;500;700&amp;display=swap"><link rel="modulepreload" href="\{url}">
  @moonback.Html::raw(raw)
}

///|
pub fn repository_assets_head(
  assets : Map[String, String],
  code_view~ : Bool = false,
) -> @moonback.Html {
  let script = vite_manifest_entry_path(assets, "src/repo-clone.ts")
  @moonback.Html(b => {
    if code_view {
      b <+ "\{custom_elements_head(assets)}"
    }
    b <+ "<link rel=\"modulepreload\" href=\"\{script}\">"
  })
}
