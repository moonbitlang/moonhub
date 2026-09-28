///|
pub async fn save_branch_rule(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  git_dir : String,
  actor : @domain.CurrentUser,
  branch : String,
  protect : Bool,
  approvals : Int64,
) -> Unit {
  @repository.authorize_repository(pool, actor, scope.repo, @repository.Write)
  guard @identity.can_manage_team(pool, actor, scope.team_id) else {
    raise @domain.Forbidden(message="team owner or admin required")
  }
  let (code, _) = @gitops.merge_git_command(git_dir, [
    "check-ref-format",
    "refs/heads/\{branch}",
  ])
  guard code == 0 &&
    !branch.is_empty() &&
    branch.length() <= 200 &&
    (approvals == 0L || approvals == 1L) else {
    raise @domain.BadRequest(message="invalid branch protection rule")
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      if protect {
        let _ = tx.execute(
          "INSERT INTO branch_rule (repository_id, branch, required_approvals) VALUES (?, ?, ?) ON CONFLICT (repository_id, branch) DO UPDATE SET required_approvals = excluded.required_approvals",
          params=[scope.id, branch, approvals],
        )
      } else {
        let _ = tx.execute(
          "DELETE FROM branch_rule WHERE repository_id = ? AND branch = ?",
          params=[scope.id, branch],
        )
      }
      let _ = tx.execute(
        "INSERT INTO repository_audit (repository_id, actor_id, kind, detail) VALUES (?, ?, ?, ?)",
        params=[
          scope.id,
          actor.id,
          if protect {
            "branch_protected"
          } else {
            "branch_unprotected"
          },
          "\{branch}; required approvals: \{approvals}",
        ],
      )
    })
  })
}

///|
pub fn authorize_received_refs(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  updates : String,
) -> Unit raise {
  @repository.authorize_repository(pool, actor, repo, @repository.Write)
  let scope = @repository.repository_scope(pool, actor, repo)
  check_received_ref_rules(pool, scope, updates)
}

///|
// Authentication is transport-specific; all writers share these ref restrictions.
pub fn check_received_ref_rules(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  updates : String,
) -> Unit raise {
  for line in @domain.split_lines(updates) {
    let fields = line.split(" ").map(value => value.to_owned()).collect()
    guard fields.length() == 3 &&
      @gitops.valid_commit_sha(fields[0]) &&
      @gitops.valid_commit_sha(fields[1]) else {
      raise @domain.BadRequest(message="invalid ref update")
    }
    let reference = fields[2]
    guard reference.has_prefix("refs/heads/") ||
      reference.has_prefix("refs/tags/") else {
      raise @domain.Forbidden(message="only branch and tag updates are allowed")
    }
    if reference.strip_prefix("refs/heads/") is Some(branch) {
      let is_protected = pool.with_client(client => {
        client.query_opt(
          "SELECT branch FROM branch_rule WHERE repository_id = ? AND branch = ?",
          params=[scope.id, branch.to_owned()],
        )
        is Some(_)
      })
      guard !is_protected else {
        raise @domain.Forbidden(
          message="branch '\{branch}' is protected; use a merge request",
        )
      }
    }
  }
}

///|
pub struct BranchRule {
  branch : String
  required_approvals : Int64
}

///|
pub fn branch_rules(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
) -> Array[BranchRule] raise {
  pool.with_client(client => {
    client
    .query_all(
      "SELECT branch, required_approvals FROM branch_rule WHERE repository_id = ? ORDER BY branch",
      params=[scope.id],
    )
    .map(row => {
      branch: row.get_name("branch"),
      required_approvals: row.get_name("required_approvals"),
    })
  })
}
