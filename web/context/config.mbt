///|
extenum @moonback.TypedBox += {
  RepoRoot(String)
  AssetsRoot(String)
}

///|
pub let config_root : @moonback.TypedKey[String] = TypedKey(
  name="moonhub.root",
  box=root => RepoRoot(root),
  unbox=err => {
    match err {
      RepoRoot(root) => Some(root)
      _ => None
    }
  },
)

///|
pub let config_assets_root : @moonback.TypedKey[String] = TypedKey(
  name="moonhub.assets_root",
  box=root => AssetsRoot(root),
  unbox=err => {
    match err {
      AssetsRoot(root) => Some(root)
      _ => None
    }
  },
)

///|
extenum @moonback.TypedBox += {
  DbPool(@database.Database)
}

///|
pub let config_db_pool : @moonback.TypedKey[@database.Database] = TypedKey(
  name="moonhub.db_pool",
  box=pool => DbPool(pool),
  unbox=err => {
    match err {
      DbPool(pool) => Some(pool)
      _ => None
    }
  },
)

///|
extenum @moonback.TypedBox += {
  RepositoryImportConfig(@repository.RepoImportConfig)
}

///|
pub let config_repo_import : @moonback.TypedKey[@repository.RepoImportConfig] = TypedKey(
  name="moonhub.repo_import",
  box=config => RepositoryImportConfig(config),
  unbox=value => {
    match value {
      RepositoryImportConfig(config) => Some(config)
      _ => None
    }
  },
)

///|
extenum @moonback.TypedBox += {
  SshAddresses(@repository.SshAddressConfig)
}

///|
pub let config_ssh_addresses : @moonback.TypedKey[@repository.SshAddressConfig] = TypedKey(
  name="moonhub.ssh_addresses",
  box=value => SshAddresses(value),
  unbox=value => {
    match value {
      SshAddresses(config) => Some(config)
      _ => None
    }
  },
)
