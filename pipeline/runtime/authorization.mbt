///|
pub fn require_run_author(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> @repository.RepositoryScope raise {
  let current = @identity.active_user_by_name(pool, actor.name_key)
  guard current.id == actor.id else {
    raise @domain.Unauthorized(message="account changed")
  }
  let scope = @repository.repository_scope(pool, current, repo)
  @repository.authorize_repository(pool, current, repo, Write)
  guard @identity.can_manage_team(pool, current, scope.team_id) else {
    raise @domain.Forbidden(
      message="repository owner or admin required to create a pipeline run",
    )
  }
  scope
}
