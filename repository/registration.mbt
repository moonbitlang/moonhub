///|
pub async fn create_managed_repository(
  pool : @database.Database,
  root : String,
  repo : @domain.RepoId,
  visibility : String,
  import_existing : Bool,
) -> Unit {
  guard visibility == "public" || visibility == "private" else {
    raise @domain.BadRequest(message="visibility must be public or private")
  }
  guard @identity.get_team_by_name_key(pool, repo.owner) is Some(team) else {
    raise @domain.NotFound(
      message="repository owner must be an existing personal or organization team",
    )
  }
  let exists = pool.with_client(client => {
    client.query_opt(
      "SELECT id FROM repository WHERE team_id = ? AND name = ?",
      params=[team.id, repo.name],
    )
  })
  guard exists is None else {
    raise @domain.BadRequest(message="repository is already registered")
  }
  let root = @domain.trim_trailing_slash(@fs.realpath(root))
  let git_dir = repo.git_dir(root)
  if import_existing {
    let _ = resolve_repository_dir(root, repo)
  } else {
    guard !@fs.exists(git_dir) else {
      raise @domain.BadRequest(
        message="repository directory already exists; use --import to register it",
      )
    }
    let owner_dir = "\{root}/\{repo.owner}"
    if !@fs.exists(owner_dir) {
      @fs.mkdir(owner_dir, permission=0o750)
    }
    guard @fs.realpath(owner_dir) == owner_dir else {
      raise @domain.BadRequest(
        message="repository owner directory must not be a symbolic link",
      )
    }
    let (code, output) = @process.collect_output_merged("git", [
      "init", "--bare", "--initial-branch=main", git_dir,
    ])
    guard code == 0 else {
      raise @domain.BadRequest(message="git init failed: \{output.text()}")
    }
  }
  let bare = @gitops.run_git(git_dir, ["rev-parse", "--is-bare-repository"])
  guard bare.trim() == "true" else {
    raise @domain.BadRequest(message="only bare repositories can be registered")
  }
  pool.with_client(client => {
    let _ = client.execute(
      "INSERT INTO repository (team_id, name, visibility) VALUES (?, ?, ?)",
      params=[team.id, repo.name, visibility],
    )
  })
}
