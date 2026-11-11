///|
#derive(Eq, Debug)
pub(all) enum RepoOperation {
  Read
  Write
}

///|
pub fn can_access_repository(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  operation : RepoOperation,
) -> Bool raise {
  pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT repository.visibility, actor.is_site_admin, team_member.role
        #|FROM repository
        #|JOIN team ON team.id = repository.team_id
        #|JOIN "user" AS actor ON actor.id = ? AND actor.status = 'active'
        #|LEFT JOIN team_member ON team_member.team_id = team.id
        #|  AND team_member.user_id = actor.id
        #|WHERE team.name_key = ? AND repository.name = ? AND repository.ready = 1
      ),
      params=[actor.id, repo.owner, repo.name],
    )
    guard row is Some(row) else { return false }
    let is_admin : Bool = row.get_name("is_site_admin")
    let role : String? = row.get_name("role")
    let visibility : String = row.get_name("visibility")
    is_admin ||
    role is Some("owner" | "admin" | "member") ||
    (operation == Read && visibility == "public")
  })
}

///|
pub fn authorize_repository(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  operation : RepoOperation,
) -> Unit raise {
  guard can_access_repository(pool, actor, repo, operation) else {
    // Do not reveal whether a private repository exists to an unauthorized user.
    raise @domain.NotFound(message="repository not found or access denied")
  }
}

///|
/// Anonymous readers may only see registered, ready, public repositories.
/// Authenticated readers retain the existing active-account and membership policy.
pub fn can_read_repository(
  pool : @database.Database,
  actor : @domain.CurrentUser?,
  repo : @domain.RepoId,
) -> Bool raise {
  match actor {
    Some(actor) => can_access_repository(pool, actor, repo, Read)
    None =>
      pool.with_client(client => {
        client.query_opt(
          (
            #|SELECT repository.id FROM repository
            #|JOIN team ON team.id = repository.team_id
            #|WHERE team.name_key = ? AND repository.name = ?
            #|  AND repository.ready = 1 AND repository.visibility = 'public'
          ),
          params=[repo.owner, repo.name],
        )
        is Some(_)
      })
  }
}

///|
pub async fn visible_repositories(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser?,
) -> Array[@domain.RepoId] {
  let repos = @gitops.list_repositories(root)
  repos.filter(repo => can_read_repository(pool, actor, repo))
}

///|
/// Repositories of a namespace that the actor may see. A manager also sees
/// names that are still being prepared, so their status page stays reachable.
pub fn namespace_repositories(
  pool : @database.Database,
  actor : @domain.CurrentUser?,
  team : @identity.TeamSummary,
  can_manage : Bool,
) -> Array[TeamRepository] raise {
  let repositories = team_repositories(pool, team)
  if can_manage {
    repositories
  } else {
    repositories.filter(repo => {
      can_read_repository(pool, actor, {
        owner: team.name_key,
        name: repo.name,
      })
    })
  }
}

///|
pub async fn resolve_repository_dir(
  root : String,
  repo : @domain.RepoId,
) -> String {
  let root = @domain.trim_trailing_slash(@fs.realpath(root))
  let expected = repo.git_dir(root)
  let actual = @fs.realpath(expected) catch {
    _ => raise @domain.NotFound(message="repository not found")
  }
  // An alias to another namespace must not bypass that namespace's ACL.
  guard actual == expected && @fs.exists("\{actual}/HEAD") else {
    raise @domain.NotFound(message="repository not found")
  }
  actual
}
