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
      let repo : @domain.RepoId = {
        owner: field(body, "owner"),
        name: field(body, "name"),
      }
      @dto.repository_json(
        @repository.create_empty_repository(
          pool,
          root,
          actor,
          repo,
          field(body, "visibility", fallback="private"),
          addresses,
        ),
      )
    }),
  )
  ctx.get(
    "/repos/:owner/:repo",
    api_handler(req => {
      let actor = api_actor(pool, req, "read")
      let repo = @web_context.repo_param(req)
      @dto.repository_json(
        @repository.repository_details(pool, root, actor, repo, addresses),
      )
    }),
  )
})
