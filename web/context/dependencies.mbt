///|
pub(all) struct BrowserAccess {
  repositories : async (@moonback.Request) -> Array[@domain.RepoId]
  personal_owner : async (@moonback.Request) -> String?
  authorize : (@moonback.Request, @domain.RepoId) -> Unit raise
  clone_url : (@domain.RepoId) -> String? raise
  manager : (@moonback.Request, @domain.RepoId) -> Bool raise
}

///|
extenum @moonback.TypedBox += {
  AssetPaths(Map[String, String])
  BrowserAccessDependency(BrowserAccess)
}

///|
pub let asset_paths_key : @moonback.TypedKey[Map[String, String]] = TypedKey(
  name="moonhub.asset_paths",
  box=value => AssetPaths(value),
  unbox=value => {
    match value {
      AssetPaths(paths) => Some(paths)
      _ => None
    }
  },
)

///|
pub let browser_access_key : @moonback.TypedKey[BrowserAccess] = TypedKey(
  name="moonhub.browser_access",
  box=value => BrowserAccessDependency(value),
  unbox=value => {
    match value {
      BrowserAccessDependency(access) => Some(access)
      _ => None
    }
  },
)
