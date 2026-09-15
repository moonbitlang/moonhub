///|
async fn save_branch_rule(
  pool : Database,
  scope : RepositoryScope,
  git_dir : String,
  actor : CurrentUser,
  branch : String,
  protect : Bool,
  approvals : Int64,
) -> Unit {
  authorize_repository(pool, actor, scope.repo, Write)
  guard can_manage_team(pool, actor, scope.team_id) else {
    raise Forbidden(message="team owner or admin required")
  }
  let (code, _) = @gitops.merge_git_command(git_dir, [
    "check-ref-format",
    "refs/heads/\{branch}",
  ])
  guard code == 0 &&
    !branch.is_empty() &&
    branch.length() <= 200 &&
    (approvals == 0L || approvals == 1L) else {
    raise BadRequest(message="invalid branch protection rule")
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
fn authorize_received_refs(
  pool : Database,
  actor : CurrentUser,
  repo : RepoId,
  updates : String,
) -> Unit raise {
  authorize_repository(pool, actor, repo, Write)
  let scope = repository_scope(pool, actor, repo)
  for line in split_lines(updates) {
    let fields = line.split(" ").map(value => value.to_owned()).collect()
    guard fields.length() == 3 &&
      @gitops.valid_commit_sha(fields[0]) &&
      @gitops.valid_commit_sha(fields[1]) else {
      raise BadRequest(message="invalid ref update")
    }
    let reference = fields[2]
    guard reference.has_prefix("refs/heads/") ||
      reference.has_prefix("refs/tags/") else {
      raise Forbidden(message="only branch and tag updates are allowed")
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
        raise Forbidden(
          message="branch '\{branch}' is protected; use a merge request",
        )
      }
    }
  }
}

///|
async fn check_received_refs(
  pool : Database,
  key_id : Int64,
  repo : RepoId,
) -> Unit {
  let bytes = FixedArray::make(1048577, b'\x00')
  let mut length = 0
  while length < bytes.length() {
    let count = @stdio.stdin.read(
      bytes,
      offset=length,
      max_len=bytes.length() - length,
    )
    if count == 0 {
      break
    }
    length += count
  }
  guard length <= 1048576 else {
    raise BadRequest(message="too many ref updates")
  }
  let updates = @utf8.decode(Bytes::from_array(bytes)[:length]) catch {
    _ => raise BadRequest(message="invalid ref update encoding")
  }
  authorize_received_refs(pool, ssh_key_user(pool, key_id), repo, updates)
}
