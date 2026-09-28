///|
pub(all) enum SshCredential {
  UserKey(Int64)
  DeployKey(Int64)
}

///|
pub fn SshCredential::parse(value : String) -> SshCredential raise {
  let deploy = value.has_prefix("deploy:")
  let number = if deploy { value[7:].to_owned() } else { value }
  let id = @string.parse_int64(number) catch {
    _ => raise @domain.BadRequest(message="invalid SSH credential")
  }
  guard id > 0L else {
    raise @domain.BadRequest(message="invalid SSH credential")
  }
  if deploy {
    DeployKey(id)
  } else {
    UserKey(id)
  }
}

///|
fn SshCredential::argument(self : SshCredential) -> String {
  match self {
    UserKey(id) => id.to_string()
    DeployKey(id) => "deploy:\{id}"
  }
}

///|
fn deploy_key_binding(
  pool : @database.Database,
  key_id : Int64,
) -> (@repository.RepositoryScope, Bool) raise {
  pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT r.id, r.team_id, t.name_key AS owner, r.name, k.write_access
        #|FROM repository_deploy_key k JOIN repository r ON r.id = k.repository_id
        #|JOIN team t ON t.id = r.team_id
        #|WHERE k.id = ? AND k.revoked_at IS NULL AND r.ready = 1
      ),
      params=[key_id],
    )
    guard row is Some(row) else {
      raise @domain.Unauthorized(message="SSH key is not authorized")
    }
    (
      {
        id: row.get_name("id"),
        team_id: row.get_name("team_id"),
        repo: { owner: row.get_name("owner"), name: row.get_name("name"), },
      },
      row.get_name("write_access"),
    )
  })
}

///|
fn authorize_git_operation(
  pool : @database.Database,
  credential : SshCredential,
  repo : @domain.RepoId,
  operation : @repository.RepoOperation,
) -> @repository.RepositoryScope raise {
  match credential {
    UserKey(id) => {
      let user = ssh_key_user(pool, id)
      @repository.authorize_repository(pool, user, repo, operation)
      @repository.repository_scope(pool, user, repo)
    }
    DeployKey(id) => {
      let (scope, write_access) = deploy_key_binding(pool, id)
      guard scope.repo.path() == repo.path() &&
        (operation == @repository.Read || write_access) else {
        raise @domain.NotFound(message="repository not found or access denied")
      }
      scope
    }
  }
}
