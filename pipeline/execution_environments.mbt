///|
#derive(Debug, ToJson, FromJson)
pub(all) struct ExecutionEnvironmentConfig {
  label : String
  architecture : String
  environment_version : String
  routing : String
  restricted_provider : String
  linux_ci_provider : String
}

///|
#derive(Debug, ToJson)
pub struct ExecutionEnvironment {
  name : String
  revision : String
  config : ExecutionEnvironmentConfig
}

///|
fn execution_environment(row : @database.DbRow) -> ExecutionEnvironment raise {
  {
    name: row.get_name("name"),
    revision: (row.get_name("revision") : Int64).to_string(),
    config: {
      label: row.get_name("label"),
      architecture: row.get_name("architecture"),
      environment_version: row.get_name("environment_version"),
      routing: row.get_name("routing"),
      restricted_provider: (row.get_name("restricted_name") : String?).unwrap_or(
        "",
      ),
      linux_ci_provider: (row.get_name("ci_name") : String?).unwrap_or(""),
    },
  }
}

///|
let execution_environment_select : String =
  #|SELECT e.*, p.name restricted_name, c.name ci_name
  #|FROM pipeline_execution_environment e
  #|LEFT JOIN pipeline_provider p ON p.id=e.restricted_provider_id
  #|LEFT JOIN pipeline_provider c ON c.id=e.linux_ci_provider_id

///|
pub fn Coordinator::execution_environments(
  self : Coordinator,
  actor : @domain.CurrentUser,
) -> Array[ExecutionEnvironment] raise {
  require_provider_admin(self.pool, actor)
  self.pool.with_client(c => {
    c
    .query_all(execution_environment_select + " ORDER BY e.name")
    .map(execution_environment)
  })
}

///|
fn execution_provider(
  tx : @database.DbTransaction,
  name : String,
  config : ExecutionEnvironmentConfig,
  ci : Bool,
) -> Int64 raise {
  if name.is_empty() {
    guard config.routing == (if ci { "restricted" } else { "linux-ci" }) else {
      raise @domain.BadRequest(
        message="This routing policy requires both execution providers.",
      )
    }
    return 0L
  }
  let p = tx.query_opt(
    "SELECT * FROM pipeline_provider WHERE name=? AND revoked=0",
    params=[name],
  )
  guard p is Some(p) else {
    raise @domain.BadRequest(message="Execution provider not found.")
  }
  let values : Map[String, String] = @json.from_json(
    @json.parse((p.get_name("config_json") : String)),
  )
  let labels = tx
    .query_all(
      "SELECT label FROM pipeline_provider_label WHERE provider_id=?",
      params=[(p.get_name("id") : Int64)],
    )
    .map(r => (r.get_name("label") : String))
  guard labels.contains("linux") &&
    labels.contains(config.label) &&
    labels.contains(config.architecture) &&
    ["docker", "asg"].contains((p.get_name("mode") : String)) &&
    (values.get("execution_mode") == Some("linux-ci")) == ci &&
    (!ci || (p.get_name("mode") : String) == "asg") else {
    raise @domain.BadRequest(
      message="Provider does not satisfy this execution environment and isolation profile.",
    )
  }
  p.get_name("id")
}

///|
pub fn Coordinator::save_execution_environment(
  self : Coordinator,
  actor : @domain.CurrentUser,
  name : String,
  revision : Int64,
  config : ExecutionEnvironmentConfig,
) -> Unit raise {
  require_provider_admin(self.pool, actor)
  guard @domain.valid_segment(name) &&
    name.length() <= 64 &&
    ["ubuntu-22.04", "ubuntu-24.04", "ubuntu-latest"].contains(config.label) &&
    ["x64", "arm64"].contains(config.architecture) &&
    @domain.valid_segment(config.environment_version) &&
    config.environment_version.length() <= 64 &&
    ["restricted", "linux-ci", "adaptive"].contains(config.routing) else {
    raise @domain.BadRequest(message="Invalid Linux execution environment.")
  }
  self.pool.with_client(c => {
    c.with_transaction(
      tx => {
        let previous = tx.query_opt(
          "SELECT * FROM pipeline_execution_environment WHERE name=?",
          params=[name],
        )
        guard previous.map(r => (r.get_name("revision") : Int64)).unwrap_or(0L) ==
          revision else {
          raise Conflict("Execution environment changed. Reload before saving.")
        }
        let restricted = execution_provider(
          tx,
          config.restricted_provider,
          config,
          false,
        )
        let ci = execution_provider(tx, config.linux_ci_provider, config, true)
        guard tx.query_opt(
            "SELECT id FROM pipeline_execution_environment WHERE label=? AND architecture=? AND name<>?",
            params=[config.label, config.architecture, name],
          )
          is None else {
          raise Conflict("This platform already has an execution environment.")
        }
        if previous is Some(old) {
          guard (old.get_name("label") : String) == config.label &&
            (old.get_name("architecture") : String) == config.architecture else {
            raise @domain.BadRequest(
              message="Create a new environment to change its operating system or architecture.",
            )
          }
        }
        ignore(
          tx.execute(
            "INSERT INTO pipeline_execution_environment(name,label,architecture,environment_version,routing,restricted_provider_id,linux_ci_provider_id,revision) VALUES(?,?,?,?,?,NULLIF(?,0),NULLIF(?,0),1) ON CONFLICT(name) DO UPDATE SET environment_version=excluded.environment_version,routing=excluded.routing,restricted_provider_id=excluded.restricted_provider_id,linux_ci_provider_id=excluded.linux_ci_provider_id,revision=pipeline_execution_environment.revision+1",
            params=[
              name,
              config.label,
              config.architecture,
              config.environment_version,
              config.routing,
              restricted,
              ci,
            ],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
#derive(Debug, ToJson)
pub struct ExecutionPolicy {
  capability_retry : Bool
  revision : String
}

///|
pub fn execution_policy(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> ExecutionPolicy raise {
  let scope = @repository.repository_scope(pool, actor, repo)
  pool.with_client(c => {
    c
    .query_opt(
      "SELECT * FROM pipeline_execution_policy WHERE repository_id=?",
      params=[scope.id],
    )
    .map(r => {
      (
        {
          capability_retry: r.get_name("capability_retry"),
          revision: (r.get_name("revision") : Int64).to_string(),
        } : ExecutionPolicy)
    })
    .unwrap_or({ capability_retry: false, revision: "0", })
  })
}

///|
pub fn save_execution_policy(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  revision : Int64,
  capability_retry : Bool,
) -> Unit raise {
  let scope = require_run_author(pool, actor, repo)
  pool.with_client(c => {
    c.with_transaction(
      tx => {
        let existing = tx.query_opt(
          "SELECT revision FROM pipeline_execution_policy WHERE repository_id=?",
          params=[scope.id],
        )
        guard existing.map(r => (r.get_name("revision") : Int64)).unwrap_or(0L) ==
          revision else {
          raise Conflict("Execution policy changed. Reload before saving.")
        }
        ignore(
          tx.execute(
            "INSERT INTO pipeline_execution_policy(repository_id,capability_retry,revision) VALUES(?,?,1) ON CONFLICT(repository_id) DO UPDATE SET capability_retry=excluded.capability_retry,revision=pipeline_execution_policy.revision+1",
            params=[scope.id, capability_retry],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
fn snapshot_execution_routes(
  tx : @database.DbTransaction,
  run : Run,
) -> Unit raise {
  let retry = tx
    .query_opt(
      "SELECT capability_retry FROM pipeline_execution_policy WHERE repository_id=?",
      params=[run.repository_id],
    )
    .map(r => (r.get_name("capability_retry") : Bool))
    .unwrap_or(false)
  let trust = tx
    .query_opt("SELECT scope FROM pipeline_cache_scope WHERE run_id=?", params=[
      run.id,
    ])
    .map(r => (r.get_name("scope") : String))
    .unwrap_or("run:" + run.id.to_string())
  let environments = tx.query_all(
    "SELECT * FROM pipeline_execution_environment",
  )
  for job in run.definition.jobs {
    let e = environments
      .iter()
      .find_first(e => {
        job.runs_on.contains((e.get_name("label") : String)) &&
        job.runs_on.contains((e.get_name("architecture") : String))
      })
    guard e is Some(e) else { continue }
    let environment_version : String = e.get_name("environment_version")
    let matrix = job.matrix.to_array()
    matrix.sort_by((a, b) => a.0.compare(b.0))
    let key = @identity.hash_token(
      (
        {
          "classifier": 1,
          "workflow_path": run.workflow_path,
          "workflow_source": run.workflow_source,
          "job": job.id,
          "matrix": ToJson::to_json(matrix),
          "environment": (e.get_name("name") : String),
          "version": environment_version,
        } : Json).stringify(),
    )
    let learned = tx.query_opt(
        "SELECT capability FROM pipeline_execution_learning WHERE repository_id=? AND learning_key=? AND trust_scope=? LIMIT 1",
        params=[run.repository_id, key, trust],
      )
      is Some(_)
    let mode : String = e.get_name("routing")
    let profile = if mode == "linux-ci" || (mode == "adaptive" && learned) {
      "linux-ci"
    } else {
      "restricted"
    }
    ignore(
      tx.execute(
        "INSERT INTO pipeline_job_execution(job_id,environment_id,environment_version,learning_key,trust_scope,routing,profile,reason,retry_allowed) SELECT id,?,?,?,?,?,?,?,? FROM pipeline_job WHERE run_id=? AND job_key=?",
        params=[
          (e.get_name("id") : Int64),
          environment_version,
          key,
          trust,
          mode,
          profile,
          if mode != "adaptive" {
            "fixed"
          } else if learned {
            "learned_requirement"
          } else {
            "initial_probe"
          },
          retry,
          run.id,
          job.id,
        ],
      ),
    )
  }
}

///|
#deprecated
pub extend ExecutionEnvironmentConfig with @debug.Debug::{to_repr}

///|
#deprecated
pub extend ExecutionEnvironmentConfig with ToJson::{to_json}

///|
#deprecated
pub extend ExecutionEnvironmentConfig with @json.FromJson::{from_json}

///|
#deprecated
pub extend ExecutionEnvironment with @debug.Debug::{to_repr}

///|
#deprecated
pub extend ExecutionEnvironment with ToJson::{to_json}

///|
#deprecated
pub extend ExecutionPolicy with @debug.Debug::{to_repr}

///|
#deprecated
pub extend ExecutionPolicy with ToJson::{to_json}
