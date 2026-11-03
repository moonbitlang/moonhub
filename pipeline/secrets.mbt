///|
#derive(Debug)
pub struct RepositorySecret {
  name : String
  branch : String
  workflow_path : String
  version : Int64
  created_at : String
  updated_at : String
}

///|
pub fn list_secrets(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> Array[RepositorySecret] raise {
  let scope = require_run_author(pool, actor, repo)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT name, branch, workflow_path, version, created_at, updated_at FROM repository_secret WHERE repository_id = ? ORDER BY name",
      params=[scope.id],
    )
    .map(row => {
      name: row.get_name("name"),
      branch: row.get_name("branch"),
      workflow_path: row.get_name("workflow_path"),
      version: row.get_name("version"),
      created_at: row.get_name("created_at"),
      updated_at: row.get_name("updated_at"),
    })
  })
}

///|
pub async fn save_secret(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  name : String,
  value : String?,
  branch : String,
  workflow_path : String,
  version : Int64,
) -> Unit {
  ignore(require_run_author(pool, actor, repo))
  guard @workflow.valid_secret_name(name) && version >= 0L else {
    raise @domain.BadRequest(
      message="Use a secret name containing letters, numbers and underscores, without a reserved prefix or leading number.",
    )
  }
  let name = name.to_upper()
  if value is Some(value) {
    guard !value.is_empty() &&
      !value.contains("\u{0000}") &&
      @utf8.encode(value).length() <= 16384 else {
      raise @domain.BadRequest(
        message="Secret values must contain 1 to 16,384 UTF-8 bytes and no NUL characters.",
      )
    }
  }
  validate_workflow_path(workflow_path)
  @repository.with_repository_write(pool, root, actor, repo, (scope, dir) => {
    ignore(require_run_author(pool, actor, repo))
    ignore(@gitops.branch_sha(dir, branch)) catch {
      @gitops.Failure(_) =>
        raise @domain.BadRequest(
          message="Choose an existing branch for this secret.",
        )
      err => raise err
    }
    // Git validation yields; recheck access before persisting any credential.
    ignore(require_run_author(pool, actor, repo))
    pool.with_client(client => {
      client.with_transaction(
        tx => {
          let existing = tx.query_opt(
            "SELECT version, value FROM repository_secret WHERE repository_id = ? AND name = ?",
            params=[scope.id, name],
          )
          if existing is Some(existing) {
            guard (existing.get_name("version") : Int64) == version else {
              raise Conflict(
                "Secret changed. Reload its settings before saving.",
              )
            }
          } else {
            guard version == 0L else {
              raise Conflict(
                "Secret was deleted. Reload its settings before saving.",
              )
            }
            guard value is Some(_) else {
              raise @domain.BadRequest(
                message="Enter a value for the new secret.",
              )
            }
            let count : Int64 = tx
              .query_one(
                "SELECT COUNT(*) AS total FROM repository_secret WHERE repository_id = ?",
                params=[scope.id],
              )
              .get_name("total")
            guard count < 64L else {
              raise @domain.BadRequest(
                message="Each repository supports at most 64 secrets.",
              )
            }
          }
          let saved_value = value.unwrap_or_else(() => {
            existing.unwrap().get_name("value")
          })
          // The AUTOINCREMENT revision survives deletion/recreation of a name.
          ignore(
            tx.execute(
              "INSERT INTO repository_secret (repository_id, name, value, branch, workflow_path) VALUES (?, ?, ?, ?, ?) ON CONFLICT(repository_id, name) DO UPDATE SET value = excluded.value, branch = excluded.branch, workflow_path = excluded.workflow_path, version = excluded.version, updated_at = datetime('now')",
              params=[scope.id, name, saved_value, branch, workflow_path],
            ),
          )
          ignore(
            tx.execute(
              "INSERT INTO repository_audit (repository_id, actor_id, kind, detail) VALUES (?, ?, 'secret_saved', ?)",
              params=[scope.id, actor.id, name],
            ),
          )
        },
        immediate=true,
      )
    })
  })
}

///|
pub fn delete_secret(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  name : String,
  version : Int64,
) -> Unit raise {
  let scope = require_run_author(pool, actor, repo)
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        guard tx.execute(
            "DELETE FROM repository_secret WHERE repository_id = ? AND name = ? AND version = ?",
            params=[scope.id, name.to_upper(), version],
          ) ==
          1 else {
          raise Conflict(
            "Secret changed or was deleted. Reload its settings before deleting.",
          )
        }
        ignore(
          tx.execute(
            "INSERT INTO repository_audit (repository_id, actor_id, kind, detail) VALUES (?, ?, 'secret_deleted', ?)",
            params=[scope.id, actor.id, name.to_upper()],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
fn require_secret_policy(
  tx : @database.DbTransaction,
  repository_id : Int64,
  name : String,
  branch : String,
  workflow_path : String,
  context : @workflow.RunContext?,
) -> Unit raise {
  guard context is Some(context) &&
    ["workflow_dispatch", "push"].contains(context.event_name) else {
    raise @domain.Forbidden(
      message="Repository secrets are available only to authorized manual and push workflows, never MR checks.",
    )
  }
  guard tx.query_opt(
      "SELECT name FROM repository_secret WHERE repository_id = ? AND name = ? AND branch = ? AND workflow_path = ?",
      params=[repository_id, name, branch, workflow_path],
    )
    is Some(_) else {
    raise @domain.Forbidden(
      message="Secret \{name} is missing or is not allowed for this branch and workflow.",
    )
  }
}

///|
fn validate_secret_policy(
  tx : @database.DbTransaction,
  repository_id : Int64,
  branch : String,
  workflow_path : String,
  context : @workflow.RunContext?,
  definition : @workflow.Workflow,
) -> Unit raise {
  for job in definition.jobs {
    for step in job.steps {
      for _, name in step.secret_env {
        require_secret_policy(
          tx, repository_id, name, branch, workflow_path, context,
        ) catch {
          // During planning this is an invalid workflow configuration, not a
          // revocation of the actor's repository-wide execution permission.
          // Push/MR workers can report it for this workflow and keep going.
          // Runtime delivery still returns Forbidden and never issues values.
          @domain.Forbidden(message~) => raise @domain.BadRequest(message~)
          err => raise err
        }
      }
    }
  }
}

///|
pub fn Coordinator::step_secrets(
  self : Coordinator,
  id : Int64,
  token : String,
  request : @protocol.SecretRequest,
) -> @protocol.SecretResponse raise {
  check_version(request.version)
  self.authenticate_attempt(id, token)
  ignore(self.expire_attempts())
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = load_live_attempt(tx, id, token, (self.clock)())
        guard (row.get_name("status") : String) == "running" &&
          (row.get_name("cancel_at_ms") : Int64?) is None &&
          (row.get_name("execution_id") : String?) == Some(request.execution_id) &&
          !request.execution_id.is_empty() else {
          raise Conflict("Secrets require the active execution instance.")
        }
        guard tx.query_opt(
            "SELECT step_id FROM pipeline_step WHERE attempt_id = ? AND step_id = ? AND state = 'running'",
            params=[id, request.step_id],
          )
          is Some(_) else {
          raise Conflict("Secrets require a running step.")
        }
        let job = attempt_job(row)
        let step = job.steps
          .iter()
          .find_first(step => step.id == request.step_id)
        guard step is Some(step) else {
          raise @domain.BadRequest(message="Unknown secret step.")
        }
        let run = tx.query_one("SELECT * FROM pipeline_run WHERE id = ?", params=[
          (row.get_name("run_id") : Int64),
        ])
        let context : @workflow.RunContext? = (
          run.get_name("context_json") : String?).map(text => {
          @json.from_json(@json.parse(text))
        })
        guard (run.get_name("merge_check_id") : Int64?) is None else {
          raise @domain.Forbidden(
            message="MR checks cannot access repository secrets.",
          )
        }
        let env : Map[String, String] = Map([])
        for variable, name in step.secret_env {
          require_secret_policy(
            tx,
            row.get_name("repository_id"),
            name,
            run.get_name("source_branch"),
            run.get_name("workflow_path"),
            context,
          )
          let existing = tx.query_opt(
            "SELECT value FROM pipeline_secret_delivery WHERE attempt_id = ? AND step_id = ? AND env_name = ?",
            params=[id, step.id, variable],
          )
          let value : String = match existing {
            Some(delivery) => delivery.get_name("value")
            None => {
              let value : String = tx
                .query_one(
                  "SELECT value FROM repository_secret WHERE repository_id = ? AND name = ?",
                  params=[(row.get_name("repository_id") : Int64), name],
                )
                .get_name("value")
              let bytes : Int64 = tx
                .query_one(
                  "SELECT COALESCE(SUM(length(CAST(value AS BLOB))), 0) AS total FROM pipeline_secret_delivery WHERE attempt_id = ?",
                  params=[id],
                )
                .get_name("total")
              guard bytes + @utf8.encode(value).length().to_int64() <= 262144L else {
                raise @domain.BadRequest(
                  message="Job secret values exceed 256 KiB.",
                )
              }
              ignore(
                tx.execute(
                  "INSERT INTO pipeline_secret_delivery (attempt_id, step_id, env_name, value) VALUES (?, ?, ?, ?)",
                  params=[id, step.id, variable, value],
                ),
              )
              value
            }
          }
          env[variable] = value
        }
        { version: @protocol.version, env, }
      },
      immediate=true,
    )
  })
}
