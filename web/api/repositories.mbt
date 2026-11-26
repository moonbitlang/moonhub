///|
// Unknown and invalid owners are indistinguishable to API clients.
fn api_namespace(
  pool : @database.Database,
  owner : String,
) -> @identity.TeamSummary raise {
  guard @domain.valid_repo_owner(owner) &&
    @identity.get_team_by_name_key(pool, owner) is Some(team) else {
    raise @domain.NotFound(message="namespace not found")
  }
  team
}

///|
// Uses the namespace listing's visibility rules: pending or failed creations
// are visible only to namespace managers, as on the Web namespace page.
fn api_repository_json(
  pool : @database.Database,
  addresses : @repository.SshAddressConfig,
  actor : @domain.CurrentUser,
  team : @identity.TeamSummary,
  name : String,
) -> Json raise {
  let can_manage = @identity.can_manage_team(pool, actor, team.id)
  for
    repository in @repository.namespace_repositories(
      pool,
      Some(actor),
      team,
      can_manage,
    ) {
    guard repository.name == name else { continue }
    let repo : @domain.RepoId = { owner: team.name_key, name, }
    return {
      "owner": team.name_key,
      "name": name,
      "full_name": "\{team.name_key}/\{name}",
      "visibility": repository.visibility,
      // ready, or the creation job state: pending, running or failed.
      "state": if repository.ready {
        "ready"
      } else {
        repository.status.unwrap_or("pending")
      },
      "clone_url": match @repository.effective_ssh_endpoint(pool, addresses) {
        Some(endpoint) => Json::string(endpoint.clone_url(repo))
        None => Json::null()
      },
    }
  }
  raise @domain.NotFound(message="repository not found or access denied")
}

///|
pub let repositories_api_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let root = ctx.require(@web_context.config_root)
  let addresses = ctx.require(@web_context.config_ssh_addresses)
  ctx.post(
    "/repos",
    api_handler(req => {
      let actor = api_actor(pool, req, "write")
      let body = api_body(req, ["owner", "name", "visibility"])
      let team = api_namespace(pool, field(body, "owner"))
      // The Web form's service: namespace owner/admin, name availability,
      // visibility validation and background provisioning.
      let repo = @repository.enqueue_repository(
        pool,
        root,
        actor,
        team,
        field(body, "name"),
        field(body, "visibility", fallback="private"),
        "",
        addresses~,
      )
      api_repository_json(pool, addresses, actor, team, repo.name)
    }),
  )
  ctx.get(
    "/repos/:owner/:repo",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let repo = @web_context.repo_param(req)
      api_repository_json(
        pool,
        addresses,
        actor,
        api_namespace(pool, repo.owner),
        repo.name,
      )
    }),
  )
})
