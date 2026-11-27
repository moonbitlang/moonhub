///|
pub async fn create_empty_repository(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  visibility : String,
  addresses : SshAddressConfig,
  write_token~ : String,
) -> @domain.RepositoryDetails {
  guard @domain.valid_repo_owner(repo.owner) &&
    @identity.get_team_by_name_key(pool, repo.owner) is Some(team) else {
    raise @domain.NotFound(message="namespace not found")
  }
  let endpoint = effective_ssh_endpoint(pool, addresses)
  // The provisioner strips one transport suffix. Keep API names literal.
  let repo = enqueue_repository(
    pool,
    root,
    actor,
    team,
    repo.name + ".git",
    visibility,
    "",
    addresses~,
    write_token~,
  )
  {
    repo,
    visibility,
    state: "pending",
    default_branch: None,
    clone_url: endpoint.map(endpoint => endpoint.clone_url(repo)),
  }
}

///|
pub async fn repository_details(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  addresses : SshAddressConfig,
) -> @domain.RepositoryDetails {
  let row = pool.with_client(client => {
    client.query_opt(
      (
        #|SELECT r.id, r.team_id, r.visibility, r.ready, j.status
        #|FROM repository AS r
        #|JOIN team AS t ON t.id = r.team_id
        #|LEFT JOIN repository_job AS j ON j.repository_id = r.id
        #|WHERE t.name_key = ? AND r.name = ?
      ),
      params=[repo.owner, repo.name],
    )
  })
  guard row is Some(row) else {
    raise @domain.NotFound(message="repository not found or access denied")
  }
  let scope : RepositoryScope = {
    id: row.get_name("id"),
    team_id: row.get_name("team_id"),
    repo,
  }
  let ready : Bool = row.get_name("ready")
  let default_branch = if ready {
    authorize_repository(pool, actor, repo, Read)
    let (reader, dir) = open_repository_read(pool, root, Some(actor), scope)
    defer reader.close()
    let branch = @gitops.default_ref(dir)
    authorize_repository(pool, actor, repo, Read)
    require_current_scope(pool, scope)
    if branch == "HEAD" {
      None
    } else {
      Some(branch)
    }
  } else {
    guard @identity.can_manage_team(pool, actor, scope.team_id) else {
      raise @domain.NotFound(message="repository not found or access denied")
    }
    None
  }
  let status : String? = row.get_name("status")
  {
    repo,
    visibility: row.get_name("visibility"),
    state: if ready {
      "ready"
    } else {
      status.unwrap_or("pending")
    },
    default_branch,
    clone_url: effective_ssh_endpoint(pool, addresses).map(endpoint => {
      endpoint.clone_url(repo)
    }),
  }
}
