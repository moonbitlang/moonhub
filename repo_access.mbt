///|
enum RepoOperation {
  Read
  Write
} derive(Eq, Debug)

///|
fn can_access_repository(
  pool : Database,
  actor : CurrentUser,
  repo : RepoId,
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
fn authorize_repository(
  pool : Database,
  actor : CurrentUser,
  repo : RepoId,
  operation : RepoOperation,
) -> Unit raise {
  guard can_access_repository(pool, actor, repo, operation) else {
    // Do not reveal whether a private repository exists to an unauthorized user.
    raise NotFound(message="repository not found or access denied")
  }
}

///|
async fn visible_repositories(
  pool : Database,
  root : String,
  actor : CurrentUser,
) -> Array[RepoId] {
  let repos = list_repositories(root)
  repos.filter(repo => can_access_repository(pool, actor, repo, Read))
}

///|
/// Repositories of a namespace that the actor may see. A manager also sees
/// names that are still being prepared, so their status page stays reachable.
fn namespace_repositories(
  pool : Database,
  actor : CurrentUser,
  team : TeamSummary,
  can_manage : Bool,
) -> Array[TeamRepository] raise {
  let repositories = team_repositories(pool, team)
  if can_manage {
    repositories
  } else {
    repositories.filter(repo => {
      can_access_repository(
        pool,
        actor,
        { owner: team.name_key, name: repo.name, },
        Read,
      )
    })
  }
}

///|
async fn resolve_repository_dir(root : String, repo : RepoId) -> String {
  let root = trim_trailing_slash(@fs.realpath(root))
  let expected = repo.git_dir(root)
  let actual = @fs.realpath(expected) catch {
    _ => raise NotFound(message="repository not found")
  }
  // An alias to another namespace must not bypass that namespace's ACL.
  guard actual == expected && @fs.exists("\{actual}/HEAD") else {
    raise NotFound(message="repository not found")
  }
  actual
}

///|
fn active_user_by_name(pool : Database, name : String) -> CurrentUser raise {
  pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT id, name_key, display_name, is_site_admin
        #|FROM "user" WHERE name_key = ? AND status = 'active'
      ),
      params=[name],
    )
    guard row is Some(row) else {
      raise NotFound(
        message="active user not found; accept the invitation first",
      )
    }
    {
      id: row.get_name("id"),
      name_key: row.get_name("name_key"),
      display_name: row.get_name("display_name"),
      is_site_admin: row.get_name("is_site_admin"),
    }
  })
}
