///|
pub async fn Coordinator::read_source(
  self : Coordinator,
  root : String,
  id : Int64,
  token : String,
) -> Bytes {
  self.authenticate_attempt(id, token)
  let (repo, sha) = self.pool.with_client(client => {
    let row = client.query_opt(
      (
        #|SELECT repo.name AS repo_name, team.name_key AS owner_name, r.commit_sha
        #|FROM pipeline_job_attempt a
        #|JOIN pipeline_job j ON j.id = a.job_id
        #|JOIN pipeline_run r ON r.id = j.run_id
        #|JOIN repository repo ON repo.id = r.repository_id
        #|JOIN team ON team.id = repo.team_id
        #|WHERE a.id = ? AND a.token_hash = ?
      ),
      params=[id, @identity.hash_token(token)],
    )
    guard row is Some(row) else {
      raise @domain.Unauthorized(message="invalid runner credentials")
    }
    let owner : String = row.get_name("owner_name")
    let name : String = row.get_name("repo_name")
    let sha : String = row.get_name("commit_sha")
    let repo : @domain.RepoId = { owner, name, }
    (repo, sha)
  })
  let git_dir = @repository.resolve_repository_dir(root, repo)
  let (code, output, _) = @process.collect_output(
    "git",
    [
      "-c", "core.hooksPath=/dev/null", "-c", "core.commitGraph=false", "--git-dir",
      git_dir, "archive", "--format=tar", sha,
    ],
    inherit_env=false,
    extra_env={
      "PATH": "/usr/bin:/bin",
      "HOME": "/nonexistent",
      "GIT_CONFIG_NOSYSTEM": "1",
      "GIT_CONFIG_GLOBAL": "/dev/null",
    },
  )
  guard code == 0 else {
    raise @domain.BadRequest(message="source checkout failed")
  }
  let bytes = output.binary()
  guard bytes.length().to_int64() <= @protocol.max_source_bytes else {
    raise @domain.BadRequest(message="source archive is too large")
  }
  bytes
}
