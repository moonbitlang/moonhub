///|
// Administrators grant the consuming repository an exact dependency scope.
// Credentials are write-only and never appear in the public configuration.
pub fn save_dependency_grant(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  kind : String,
  target : String,
  reference : String,
  credential : String?,
  version : Int64,
  delete~ : Bool = false,
) -> Unit raise {
  require_provider_admin(pool, actor)
  let scope = @repository.repository_scope(pool, actor, repo)
  let parsed = @actions.parse_reference(
    target + "@" + (if reference.is_empty() { "main" } else { reference }),
  ) catch {
    _ => raise @domain.BadRequest(message="invalid dependency repository/ref")
  }
  guard parsed.path.is_empty() &&
    parsed.repository == target &&
    ["github", "moonhub"].contains(kind) &&
    version >= 0L else {
    raise @domain.BadRequest(message="invalid dependency scope")
  }
  let source = if kind == "moonhub" {
    guard credential is None &&
      (
        reference.has_prefix("refs/heads/") ||
        reference.has_prefix("refs/tags/") ||
        @gitops.valid_commit_sha(reference)
      ) else {
      raise @domain.BadRequest(
        message="source grant requires an exact full ref or commit",
      )
    }
    Some(
      @repository.repository_scope(
        pool,
        actor,
        @domain.parse_transport_repo(target),
      ).id,
    )
  } else {
    guard reference.is_empty() &&
      (
        delete ||
        (
          credential is Some(value) &&
          value.length() >= 8 &&
          value.length() <= 4096 &&
          value.iter().all(c => c.to_int() > 32 && c.to_int() < 127)
        )
      ) else {
      raise @domain.BadRequest(
        message="GitHub grants require a repository-scoped download credential",
      )
    }
    None
  }
  pool.with_client(c => {
    c.with_transaction(
      tx => {
        let existing = tx.query_opt(
          "SELECT version FROM pipeline_dependency_grant WHERE repository_id=? AND kind=? AND target=? AND reference=?",
          params=[scope.id, kind, target, reference],
        )
        guard existing.map(row => row.get_name("version")).unwrap_or(0L) ==
          version else {
          raise Conflict("dependency grant changed")
        }
        let count : Int64 = tx
          .query_one(
            "SELECT count(*) n FROM pipeline_dependency_grant WHERE repository_id=?",
            params=[scope.id],
          )
          .get_name("n")
        guard delete || existing is Some(_) || count < 64L else {
          raise @domain.BadRequest(
            message="at most 64 dependency grants per repository",
          )
        }
        if delete {
          ignore(
            tx.execute(
              "DELETE FROM pipeline_dependency_grant WHERE repository_id=? AND kind=? AND target=? AND reference=?",
              params=[scope.id, kind, target, reference],
            ),
          )
        } else {
          ignore(
            tx.execute(
              "INSERT INTO pipeline_dependency_grant(repository_id,kind,target,reference,source_repository_id,credential,version) VALUES(?,?,?,?,NULLIF(?,0),NULLIF(?,''),?) ON CONFLICT(repository_id,kind,target,reference) DO UPDATE SET source_repository_id=excluded.source_repository_id,credential=excluded.credential,version=excluded.version",
              params=[
                scope.id,
                kind,
                target,
                reference,
                source.unwrap_or(0L),
                credential.unwrap_or(""),
                version + 1L,
              ],
            ),
          )
        }
      },
      immediate=true,
    )
  })
}

///|
pub fn dependency_grants(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> Json raise {
  require_provider_admin(pool, actor)
  let scope = @repository.repository_scope(pool, actor, repo)
  Json::array(
    pool.with_client(c => {
      c
      .query_all(
        "SELECT kind,target,reference,version FROM pipeline_dependency_grant WHERE repository_id=? ORDER BY kind,target,reference",
        params=[scope.id],
      )
      .map(row => {
        "kind": Json((row.get_name("kind") : String)),
        "target": Json((row.get_name("target") : String)),
        "ref": Json((row.get_name("reference") : String)),
        "version": Json((row.get_name("version") : Int64).to_string()),
      })
    }),
  )
}

///|
pub fn Coordinator::dependency_runtime(
  self : Coordinator,
  id : Int64,
  token : String,
  request : @protocol.OidcRuntimeRequest,
) -> @protocol.ApiRuntime raise {
  check_version(request.version)
  self.authenticate_attempt(id, token)
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        let row = live_attempt(tx, id, request.execution_id, (self.clock)())
        guard row.job().source_access else {
          raise @domain.Forbidden(
            message="dependency runtime requires assignment v17",
          )
        }
        let count : Int64 = tx
          .query_one(
            "SELECT count(*) n FROM pipeline_dependency_runtime WHERE attempt_id=?",
            params=[id],
          )
          .get_name("n")
        guard count < 128L else {
          raise @domain.BadRequest(message="too many dependency grants")
        }
        let credential = @identity.random_hex(32)
        ignore(
          tx.execute(
            "INSERT INTO pipeline_dependency_runtime(token_hash,attempt_id,execution_id,expires_ms) VALUES(?,?,?,?)",
            params=[
              @identity.hash_token(credential),
              id,
              request.execution_id,
              row.deadline_ms,
            ],
          ),
        )
        ignore(
          tx.execute(
            "INSERT INTO pipeline_secret_delivery(attempt_id,step_id,env_name,value) VALUES(?,?,?,?)",
            params=[
              id,
              "@dependency",
              @identity.hash_token(credential),
              credential,
            ],
          ),
        )
        { token: credential, }
      },
      immediate=true,
    )
  })
}

///|
fn Coordinator::dependency_attempt(
  self : Coordinator,
  tx : @database.DbTransaction,
  token : String,
) -> LiveAttempt raise {
  check_token(token)
  let grant = tx.query_opt(
    "SELECT * FROM pipeline_dependency_runtime WHERE token_hash=? AND expires_ms>?",
    params=[@identity.hash_token(token), (self.clock)()],
  )
  guard grant is Some(grant) else {
    raise @domain.Unauthorized(message="invalid dependency credential")
  }
  let row = live_attempt(
    tx,
    grant.get_name("attempt_id"),
    grant.get_name("execution_id"),
    (self.clock)(),
  )
  guard row.job().source_access else {
    raise @domain.Forbidden(message="dependency runtime not authorized")
  }
  let count : Int64 = tx
    .query_one(
      "SELECT COALESCE(SUM(requests),0) n FROM pipeline_dependency_runtime WHERE attempt_id=?",
      params=[row.id],
    )
    .get_name("n")
  guard count < 4096L else {
    raise @domain.BadRequest(message="dependency request budget exceeded")
  }
  ignore(
    tx.execute(
      "UPDATE pipeline_dependency_runtime SET requests=requests+1 WHERE token_hash=?",
      params=[@identity.hash_token(token)],
    ),
  )
  row
}

///|
fn dependency_run(
  tx : @database.DbTransaction,
  row : LiveAttempt,
) -> Int64 raise {
  tx
  .query_one(
    "SELECT COALESCE(public_run_id,id) id FROM pipeline_run WHERE id=?",
    params=[row.run_id],
  )
  .get_name("id")
}

///|
fn require_trusted_dependency(
  tx : @database.DbTransaction,
  row : LiveAttempt,
) -> Unit raise {
  let run = tx.query_one(
    "SELECT merge_check_id,context_json FROM pipeline_run WHERE id=?",
    params=[row.run_id],
  )
  let context : @workflow.RunContext = @json.from_json(
    @json.parse((run.get_name("context_json") : String?).unwrap_or("{}")),
  )
  require_secret_event(Some(context))
  guard (run.get_name("merge_check_id") : Int64?) is None &&
    ["push", "workflow_dispatch", "schedule"].contains(context.event_name) else {
    raise @domain.Forbidden(
      message="private dependencies require a trusted run",
    )
  }
}

///|
fn Coordinator::dependency_scope(
  self : Coordinator,
  token : String,
  kind : String,
  target : String,
  reference : String,
) -> (Int64, Int64, String, String?) raise {
  let parsed = @actions.parse_reference(target + "@" + reference) catch {
    _ => raise @domain.BadRequest(message="invalid dependency reference")
  }
  guard parsed.repository == target && parsed.path.is_empty() else {
    raise @domain.BadRequest(message="invalid dependency repository")
  }
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        let row = self.dependency_attempt(tx, token)
        let run = dependency_run(tx, row)
        if kind == "moonhub" {
          guard row.job().contents_read else {
            raise @domain.Forbidden(
              message="job permissions deny contents access",
            )
          }
          if target == row.owner_name + "/" + row.repo_name {
            guard reference == row.commit_sha else {
              raise @domain.Forbidden(
                message="primary checkout must retain the run commit",
              )
            }
            return (run, 0L, row.commit_sha, None)
          }
        }
        require_trusted_dependency(tx, row)
        let grant = tx.query_opt(
          "SELECT * FROM pipeline_dependency_grant WHERE repository_id=? AND kind=? AND target=? AND reference=?",
          params=[
            row.repository_id,
            kind,
            target,
            if kind == "github" {
              ""
            } else {
              reference
            },
          ],
        )
        guard grant is Some(grant) else {
          raise @domain.Forbidden(
            message="dependency repository/ref is not explicitly granted",
          )
        }
        if kind == "moonhub" {
          let repo = @domain.parse_transport_repo(target)
          guard tx.query_opt(
              "SELECT r.id FROM repository r JOIN team t ON t.id=r.team_id WHERE r.id=? AND r.ready=1 AND r.name=? AND t.name_key=?",
              params=[
                (grant.get_name("source_repository_id") : Int64),
                repo.name,
                repo.owner,
              ],
            )
            is Some(_) else {
            raise @domain.Forbidden(
              message="source repository grant is no longer current",
            )
          }
        }
        let pinned = tx.query_opt(
          "SELECT sha FROM pipeline_dependency_snapshot WHERE public_run_id=? AND kind=? AND target=? AND reference=?",
          params=[run, kind, target, reference],
        )
        (
          run,
          (grant.get_name("id") : Int64),
          pinned.map(row => row.get_name("sha")).unwrap_or(""),
          (grant.get_name("credential") : String?),
        )
      },
      immediate=true,
    )
  })
}

///|
fn Coordinator::pin_dependency(
  self : Coordinator,
  token : String,
  kind : String,
  target : String,
  reference : String,
  scope : (Int64, Int64, String, String?),
  sha : String,
) -> String raise {
  guard @gitops.valid_commit_sha(sha) else {
    raise @domain.BadRequest(message="dependency did not resolve to a commit")
  }
  let current = self.dependency_scope(token, kind, target, reference)
  guard current.0 == scope.0 && current.1 == scope.1 && current.3 == scope.3 else {
    raise @domain.Forbidden(message="dependency grant changed during download")
  }
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        let row = self.dependency_attempt(tx, token)
        guard dependency_run(tx, row) == scope.0 else {
          raise @domain.Unauthorized(message="dependency run changed")
        }
        let existing = tx.query_opt(
          "SELECT sha FROM pipeline_dependency_snapshot WHERE public_run_id=? AND kind=? AND target=? AND reference=?",
          params=[scope.0, kind, target, reference],
        )
        if existing is Some(row) {
          return row.get_name("sha")
        }
        let count : Int64 = tx
          .query_one(
            "SELECT count(*) n FROM pipeline_dependency_snapshot WHERE public_run_id=?",
            params=[scope.0],
          )
          .get_name("n")
        guard count < 256L else {
          raise @domain.BadRequest(
            message="dependency snapshot budget exceeded",
          )
        }
        ignore(
          tx.execute(
            "INSERT INTO pipeline_dependency_snapshot VALUES(?,?,?,?,?) ON CONFLICT DO NOTHING",
            params=[scope.0, kind, target, reference, sha],
          ),
        )
        tx
        .query_one(
          "SELECT sha FROM pipeline_dependency_snapshot WHERE public_run_id=? AND kind=? AND target=? AND reference=?",
          params=[scope.0, kind, target, reference],
        )
        .get_name("sha")
      },
      immediate=true,
    )
  })
}

///|
pub async fn Coordinator::dependency_source(
  self : Coordinator,
  root : String,
  token : String,
  target : String,
  reference : String,
  full_history : Bool,
) -> (String, Bytes) {
  let scope = self.dependency_scope(token, "moonhub", target, reference)
  let repo = @domain.parse_transport_repo(target)
  let lock = @repository.repository_read_lock(root, repo)
  defer lock.close()
  let dir = @repository.resolve_repository_dir(root, repo)
  let sha = if scope.2.is_empty() {
    @gitops.merge_git(dir, ["rev-parse", "--verify", reference + "^{commit}"])
    .trim()
    .to_owned()
  } else {
    scope.2
  }
  let sha = if scope.1 == 0L {
    sha
  } else {
    self.pin_dependency(token, "moonhub", target, reference, scope, sha)
  }
  let bytes = source_bundle(root, repo, sha, full_history~)
  let current = self.dependency_scope(token, "moonhub", target, reference)
  guard current.0 == scope.0 && current.1 == scope.1 else {
    raise @domain.Forbidden(message="source grant changed during download")
  }
  (sha, bytes)
}
