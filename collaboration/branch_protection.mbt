///|
pub async fn save_branch_rule(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
  git_dir : String,
  actor : @domain.CurrentUser,
  branch : String,
  protect : Bool,
  approvals : Int64,
  checks~ : Array[String] = [],
  allow_self_approval~ : Bool = false,
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
  guard checks.length() <= 16 else {
    raise @domain.BadRequest(
      message="at most 16 required workflows are supported",
    )
  }
  let unique : Map[String, Bool] = Map([])
  for path in checks {
    let parts = path.split("/").collect()
    guard parts.length() == 3 &&
      parts[0] == ".github" &&
      parts[1] == "workflows" &&
      path.length() <= 240 &&
      parts[2].length() > 4 &&
      (path.has_suffix(".yml") || path.has_suffix(".yaml")) &&
      parts[2].get_char(0) is Some(first) &&
      (first.is_ascii_alphabetic() || first.is_ascii_digit() || first == '_') &&
      parts[2]
      .iter()
      .all(ch => {
        ch.is_ascii_alphabetic() ||
        ch.is_ascii_digit() ||
        ['_', '-', '.'].contains(ch)
      }) &&
      !unique.contains(path) else {
      raise @domain.BadRequest(
        message="required checks must be unique YAML paths directly under .github/workflows",
      )
    }
    unique[path] = true
  }
  pool.with_client(client => {
    client.with_transaction(tx => {
      let previous : Array[String] = tx
        .query_all(
          "SELECT workflow_path FROM branch_required_check WHERE repository_id = ? AND branch = ? ORDER BY workflow_path",
          params=[scope.id, branch],
        )
        .map(row => row.get_name("workflow_path"))
      let changed = previous.length() != checks.length() ||
        previous.iter().any(path => !checks.contains(path))
      if protect {
        let _ = tx.execute(
          "INSERT INTO branch_rule (repository_id, branch, required_approvals, allow_self_approval) VALUES (?, ?, ?, ?) ON CONFLICT (repository_id, branch) DO UPDATE SET required_approvals = excluded.required_approvals, allow_self_approval = excluded.allow_self_approval",
          params=[scope.id, branch, approvals, allow_self_approval],
        )
      } else {
        let _ = tx.execute(
          "DELETE FROM branch_rule WHERE repository_id = ? AND branch = ?",
          params=[scope.id, branch],
        )
      }
      ignore(
        tx.execute(
          "DELETE FROM branch_required_check WHERE repository_id = ? AND branch = ?",
          params=[scope.id, branch],
        ),
      )
      if protect {
        for path in checks {
          ignore(
            tx.execute(
              "INSERT INTO branch_required_check (repository_id, branch, workflow_path) VALUES (?, ?, ?)",
              params=[scope.id, branch, path],
            ),
          )
        }
      }
      ignore(
        tx.execute(
          "UPDATE merge_request SET checks_poll_after = 0, check_generation = check_generation + ? WHERE repository_id = ? AND target_branch = ? AND status = 'open'",
          params=[if changed { 1L } else { 0L }, scope.id, branch],
        ),
      )
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
          "\{branch}; required approvals: \{approvals}; allow self approval: \{allow_self_approval}; checks: " +
          checks.join(", "),
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
  allow_self_approval : Bool
  checks : Array[String]
}

///|
pub fn branch_rules(
  pool : @database.Database,
  scope : @repository.RepositoryScope,
) -> Array[BranchRule] raise {
  pool.with_client(client => {
    client
    .query_all(
      "SELECT branch, required_approvals, allow_self_approval FROM branch_rule WHERE repository_id = ? ORDER BY branch",
      params=[scope.id],
    )
    .map(row => {
      branch: row.get_name("branch"),
      required_approvals: row.get_name("required_approvals"),
      allow_self_approval: row.get_name("allow_self_approval"),
      checks: required_merge_checks(pool, scope, row.get_name("branch")),
    })
  })
}
