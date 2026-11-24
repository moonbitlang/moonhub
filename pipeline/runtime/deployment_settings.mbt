///|
#derive(Debug, ToJson)
pub struct DeploymentEnvironment {
  id : Int64
  name : String
  version : Int64
  reviewers : Array[Int64]
  reviewer_names : Array[String]
  variables : Map[String, String]
  variable_versions : Map[String, Int64]
  secrets : Map[String, Int64]
}

///|
pub fn list_deployment_environments(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> Array[DeploymentEnvironment] raise {
  let scope = @repository.repository_scope(pool, actor, repo)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT * FROM repository_deployment_environment WHERE repository_id=? ORDER BY name",
      params=[scope.id],
    )
    .map(row => {
      let id : Int64 = row.get_name("id")
      let variables : Map[String, String] = Map([])
      for
        value in client.query_all(
          "SELECT name,value FROM deployment_environment_variable WHERE environment_id=?",
          params=[id],
        ) {
        variables[value.get_name("name")] = value.get_name("value")
      }
      let variable_versions : Map[String, Int64] = Map([])
      for
        value in client.query_all(
          "SELECT name,version FROM deployment_environment_variable WHERE environment_id=?",
          params=[id],
        ) {
        variable_versions[value.get_name("name")] = value.get_name("version")
      }
      let secrets : Map[String, Int64] = Map([])
      for
        value in client.query_all(
          "SELECT name,version FROM deployment_environment_secret WHERE environment_id=?",
          params=[id],
        ) {
        secrets[value.get_name("name")] = value.get_name("version")
      }
      {
        id,
        name: row.get_name("name"),
        version: row.get_name("version"),
        reviewers: @json.from_json(
          @json.parse((row.get_name("reviewers_json") : String)),
        ),
        reviewer_names: client
        .query_all(
          "SELECT name_key FROM user WHERE id IN (SELECT value FROM json_each(?)) ORDER BY name_key",
          params=[(row.get_name("reviewers_json") : String)],
        )
        .map(user => user.get_name("name_key")),
        variables,
        variable_versions,
        secrets,
      }
    })
  })
}

///|
pub fn Coordinator::save_deployment_environment(
  self : Coordinator,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  name : String,
  version : Int64,
  reviewers : Array[Int64],
) -> Unit raise {
  let scope = require_run_author(self.pool, actor, repo)
  guard !name.is_empty() &&
    name.length() <= 100 &&
    name
    .iter()
    .all(c => {
      (
        (c >= 'a' && c <= 'z') ||
        (c >= 'A' && c <= 'Z') ||
        (c >= '0' && c <= '9')
      ) ||
      c == '-' ||
      c == '_' ||
      c == '.'
    }) &&
    reviewers.length() <= 16 &&
    version >= 0L else {
    raise @domain.BadRequest(
      message="Use an environment name containing letters, numbers, dots, underscores or hyphens, and at most 16 reviewers.",
    )
  }
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        for reviewer in reviewers {
          guard tx.query_opt(
              "SELECT u.id FROM user u JOIN repository r ON r.id=? LEFT JOIN team_member tm ON tm.team_id=r.team_id AND tm.user_id=u.id WHERE u.id=? AND u.status='active' AND (u.is_site_admin=1 OR tm.role IN ('owner','admin','member'))",
              params=[scope.id, reviewer],
            )
            is Some(_) else {
            raise @domain.BadRequest(
              message="Reviewers must be active repository members.",
            )
          }
        }
        let previous = tx.query_opt(
          "SELECT id,version FROM repository_deployment_environment WHERE repository_id=? AND name=?",
          params=[scope.id, name],
        )
        if previous is Some(row) {
          guard (row.get_name("version") : Int64) == version else {
            raise Conflict("Environment changed; reload before saving.")
          }
          ignore(
            tx.execute(
              "UPDATE repository_deployment_environment SET reviewers_json=?,version=version+1 WHERE id=?",
              params=[
                ToJson::to_json(reviewers).stringify(),
                (row.get_name("id") : Int64),
              ],
            ),
          )
          let id : Int64 = row.get_name("id")
          ignore(
            tx.execute(
              "UPDATE pipeline_job_attempt SET cancel_at_ms=COALESCE(cancel_at_ms,?) WHERE status<>'completed' AND job_id IN (SELECT job_id FROM pipeline_job_deployment WHERE environment_id=?)",
              params=[(self.clock)(), id],
            ),
          )
          ignore(
            tx.execute(
              "DELETE FROM pipeline_concurrency_slot WHERE job_id IN (SELECT j.id FROM pipeline_job j JOIN pipeline_job_deployment d ON d.job_id=j.id WHERE d.environment_id=? AND j.status='queued')",
              params=[id],
            ),
          )
          ignore(
            tx.execute(
              "UPDATE pipeline_job SET status='waiting' WHERE status='queued' AND id IN (SELECT job_id FROM pipeline_job_deployment WHERE environment_id=?)",
              params=[id],
            ),
          )
        } else {
          guard version == 0L else {
            raise Conflict("Environment was deleted; reload before saving.")
          }
          guard (
              tx
              .query_one(
                "SELECT count(*) AS n FROM repository_deployment_environment WHERE repository_id=?",
                params=[scope.id],
              )
              .get_name("n") : Int64) <
            64L else {
            raise @domain.BadRequest(
              message="A repository supports at most 64 deployment environments.",
            )
          }
          ignore(
            tx.execute(
              "INSERT INTO repository_deployment_environment(repository_id,name,reviewers_json) VALUES(?,?,?)",
              params=[
                scope.id,
                name.to_lower(),
                ToJson::to_json(reviewers).stringify(),
              ],
            ),
          )
        }
        ignore(
          tx.execute(
            "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'deployment_environment_saved',?)",
            params=[scope.id, actor.id, name],
          ),
        )
        advance_all_runs(tx)
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::delete_deployment_environment(
  self : Coordinator,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  name : String,
  version : Int64,
) -> Unit raise {
  let scope = require_run_author(self.pool, actor, repo)
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = tx.query_opt(
          "SELECT id FROM repository_deployment_environment WHERE repository_id=? AND name=? AND version=?",
          params=[scope.id, name, version],
        )
        guard row is Some(row) else {
          raise Conflict("Environment changed; reload before deleting.")
        }
        let id : Int64 = row.get_name("id")
        ignore(
          tx.execute(
            "UPDATE pipeline_job_attempt SET cancel_at_ms=COALESCE(cancel_at_ms,?) WHERE status<>'completed' AND job_id IN (SELECT job_id FROM pipeline_job_deployment WHERE environment_id=?)",
            params=[(self.clock)(), id],
          ),
        )
        ignore(
          tx.execute(
            "UPDATE pipeline_job SET status='completed',conclusion='cancelled',scheduling_error='Deployment environment was deleted' WHERE status IN ('waiting','queued') AND id IN (SELECT job_id FROM pipeline_job_deployment WHERE environment_id=?)",
            params=[id],
          ),
        )
        ignore(
          tx.execute(
            "DELETE FROM repository_deployment_environment WHERE id=?",
            params=[id],
          ),
        )
        ignore(
          tx.execute(
            "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'deployment_environment_deleted',?)",
            params=[scope.id, actor.id, name],
          ),
        )
        advance_all_runs(tx)
      },
      immediate=true,
    )
  })
}

///|
// The table is selected only by this boolean. None deletes a value; credentials
// never appear in read models, audit details or conflict diagnostics.
pub fn save_deployment_value(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  environment : String,
  name : String,
  value : String?,
  version : Int64,
  secret~ : Bool,
) -> Unit raise {
  let scope = require_run_author(pool, actor, repo)
  guard @workflow.valid_secret_name(name) &&
    !["__PROTO__", "PROTOTYPE", "CONSTRUCTOR"].contains(name.to_upper()) &&
    version >= 0L else {
    raise @domain.BadRequest(message="Invalid configuration name or version.")
  }
  if value is Some(value) {
    guard !value.contains("\u{0000}") &&
      @utf8.encode(value).length() <= (if secret { 16384 } else { 49152 }) &&
      (!secret || !value.is_empty()) else {
      raise @domain.BadRequest(
        message="Configuration value exceeds its limit or contains NUL.",
      )
    }
  }
  let table = if secret {
    "deployment_environment_secret"
  } else {
    "deployment_environment_variable"
  }
  pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = tx.query_opt(
          "SELECT id FROM repository_deployment_environment WHERE repository_id=? AND name=?",
          params=[scope.id, environment],
        )
        guard row is Some(row) else {
          raise @domain.NotFound(message="Deployment environment not found.")
        }
        let id : Int64 = row.get_name("id")
        let previous = tx.query_opt(
          "SELECT version FROM \{table} WHERE environment_id=? AND name=?",
          params=[id, name],
        )
        guard previous
          .map(row => (row.get_name("version") : Int64))
          .unwrap_or(0L) ==
          version else {
          raise Conflict("Configuration changed; reload before saving.")
        }
        if value is Some(value) {
          guard (
              tx
              .query_one(
                "SELECT count(*) AS n FROM \{table} WHERE environment_id=? AND name<>?",
                params=[id, name],
              )
              .get_name("n") : Int64) <
            (if secret { 64L } else { 500L }) else {
            raise @domain.BadRequest(
              message="Too many environment configuration values.",
            )
          }
          if !secret {
            let values : Map[String, String] = Map([])
            for
              row in tx.query_all(
                "SELECT name,value FROM deployment_environment_variable WHERE environment_id=?",
                params=[id],
              ) {
              values[row.get_name("name")] = row.get_name("value")
            }
            values[name.to_upper()] = value
            guard @utf8.encode(ToJson::to_json(values).stringify()).length() <=
              262144 else {
              raise @domain.BadRequest(
                message="Environment variables exceed 256 KiB.",
              )
            }
          }
          ignore(
            tx.execute(
              "INSERT INTO \{table}(environment_id,name,value) VALUES(?,?,?) ON CONFLICT(environment_id,name) DO UPDATE SET value=excluded.value,version=excluded.version",
              params=[id, name.to_upper(), value],
            ),
          )
        } else {
          ignore(
            tx.execute(
              "DELETE FROM \{table} WHERE environment_id=? AND name=?",
              params=[id, name],
            ),
          )
        }
        ignore(
          tx.execute(
            "INSERT INTO repository_audit(repository_id,actor_id,kind,detail) VALUES(?,?,'deployment_value_changed',?)",
            params=[scope.id, actor.id, environment + "/" + name],
          ),
        )
      },
      immediate=true,
    )
  })
}
