///|
fn cancel_unscoped_attempts(
  tx : @database.DbTransaction,
  provider_id : Int64,
  now : Int64,
) -> Unit raise {
  ignore(
    tx.execute(
      (
        #|UPDATE pipeline_job_attempt SET cancel_at_ms = COALESCE(cancel_at_ms, ?)
        #|WHERE provider_id = ? AND status <> 'completed'
        #|AND EXISTS (SELECT 1 FROM pipeline_provider p WHERE p.id = pipeline_job_attempt.provider_id AND p.repository_scope = 'selected')
        #|AND NOT EXISTS (SELECT 1 FROM pipeline_provider_repository g JOIN pipeline_job j ON j.id = pipeline_job_attempt.job_id
        #|  JOIN pipeline_run r ON r.id = j.run_id WHERE g.provider_id = pipeline_job_attempt.provider_id AND g.repository_id = r.repository_id)
      ),
      params=[now, provider_id],
    ),
  )
}

///|
pub fn Coordinator::set_provider_scope(
  self : Coordinator,
  actor : @domain.CurrentUser,
  id : Int64,
  scope : ProviderScope,
  repositories : Array[@domain.RepoId],
) -> Unit raise {
  require_provider_admin(self.pool, actor)
  guard scope != AllRepositories || repositories.is_empty() else {
    raise @domain.BadRequest(
      message="All-repository scope cannot include a repository list.",
    )
  }
  guard repositories.length() <= 100 else {
    raise @domain.BadRequest(message="Select at most 100 repositories.")
  }
  let ids = repositories.map(repo => {
    @repository.repository_scope(self.pool, actor, repo).id
  })
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        guard tx.execute(
            "UPDATE pipeline_provider SET repository_scope = ? WHERE id = ? AND revoked = 0",
            params=[scope.value(), id],
          ) ==
          1 else {
          raise @domain.NotFound(message="provider not found")
        }
        ignore(
          tx.execute(
            "DELETE FROM pipeline_provider_repository WHERE provider_id = ?",
            params=[id],
          ),
        )
        for repo_id in ids {
          ignore(
            tx.execute(
              "INSERT OR IGNORE INTO pipeline_provider_repository (provider_id, repository_id) VALUES (?, ?)",
              params=[id, repo_id],
            ),
          )
        }
        cancel_unscoped_attempts(tx, id, (self.clock)())
      },
      immediate=true,
    )
  })
}
