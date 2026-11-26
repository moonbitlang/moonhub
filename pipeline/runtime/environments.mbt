///|
fn provider_environments(
  tx : @database.DbTransaction,
  provider_id : Int64,
) -> Array[@environment.Profile] raise {
  tx
  .query_all(
    "SELECT id,environment_json,is_default FROM pipeline_provider_environment WHERE provider_id=? ORDER BY id",
    params=[provider_id],
  )
  .map(row => {
    id: (row.get_name("id") : Int64).to_string(),
    environment: @json.from_json(
      @json.parse((row.get_name("environment_json") : String)),
    ),
    is_default: row.get_name("is_default"),
  })
}

///|
fn configurable_environments(
  tx : @database.DbTransaction,
  row : @database.DbRow,
) -> Bool raise {
  (row.get_name("mode") : String) == "docker" &&
  disposable_provider_os(row) is None &&
  tx.query_opt(
    "SELECT 1 FROM pipeline_provider_label WHERE provider_id=? AND label='linux'",
    params=[(row.get_name("id") : Int64)],
  )
  is Some(_)
}

///|
fn validate_environment_provider_labels(
  tx : @database.DbTransaction,
  provider_id : Int64,
  labels : Array[String],
) -> Unit raise {
  let environments = provider_environments(tx, provider_id)
  guard environments.is_empty() || labels.contains("linux") else {
    raise @domain.BadRequest(
      message="Remove named Linux environments before changing the provider operating system.",
    )
  }
  for profile in environments {
    guard @environment.is_environment_label(profile.environment.name) ||
      !labels.contains(profile.environment.name) else {
      raise @domain.BadRequest(
        message="Environment names cannot also be shared provider labels.",
      )
    }
  }
}

///|
pub fn Coordinator::save_provider_environments(
  self : Coordinator,
  actor : @domain.CurrentUser,
  provider_id : Int64,
  revision : Int64,
  values : Array[@environment.Definition],
  default_name : String,
) -> Unit raise {
  require_provider_admin(self.pool, actor)
  if @environment.validate_set(values, default_name) is Some(message) {
    raise @domain.BadRequest(message~)
  }
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = tx.query_opt(
          "SELECT * FROM pipeline_provider WHERE id=? AND revoked=0",
          params=[provider_id],
        )
        guard row is Some(row) else {
          raise @domain.NotFound(message="Provider not found.")
        }
        guard (row.get_name("config_revision") : Int64) == revision else {
          raise Conflict("Configuration changed. Reload before saving.")
        }
        guard configurable_environments(tx, row) else {
          raise @domain.BadRequest(
            message="Multiple environments require a Linux Docker provider.",
          )
        }
        guard values.is_empty() ||
          (row.get_name("environment_protocol") : Int64) == 1L else {
          raise @domain.BadRequest(
            message="Update and connect moonhub-runner before configuring multiple environments.",
          )
        }
        for value in values {
          if !@environment.is_environment_label(value.name) &&
            tx.query_opt(
              "SELECT 1 FROM pipeline_provider_label WHERE provider_id=? AND label=?",
              params=[provider_id, value.name],
            )
            is Some(_) {
            raise @domain.BadRequest(
              message="An environment name cannot also be a shared provider label.",
            )
          }
        }
        let previous = provider_environments(tx, provider_id)
        if previous.length() == values.length() &&
          previous
          .iter()
          .zip(values.iter())
          .all(pair => {
            pair.0.environment == pair.1 &&
            pair.0.is_default == (pair.1.name == default_name)
          }) {
          return
        }
        ignore(
          tx.execute(
            "DELETE FROM pipeline_provider_environment WHERE provider_id=?",
            params=[provider_id],
          ),
        )
        for value in values {
          ignore(
            tx.execute(
              "INSERT INTO pipeline_provider_environment(provider_id,name,environment_json,labels_json,is_default) VALUES(?,?,?,?,?)",
              params=[
                provider_id,
                value.name,
                ToJson::to_json(value).stringify(),
                ToJson::to_json(value.effective_labels()).stringify(),
                value.name == default_name,
              ],
            ),
          )
        }
        ignore(
          tx.execute(
            "UPDATE pipeline_provider SET config_revision=config_revision+1,control_status='pending' WHERE id=?",
            params=[provider_id],
          ),
        )
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::job_environments(
  self : Coordinator,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
) -> Map[String, @environment.Definition] raise {
  let run = get_run(self.pool, actor, repo, number)
  self.pool.with_client(client => {
    let result : Map[String, @environment.Definition] = Map([])
    for
      row in client.query_all(
        "SELECT j.job_key,e.environment_json FROM pipeline_job j JOIN pipeline_job_environment e ON e.job_id=j.id WHERE j.run_id=?",
        params=[run.id],
      ) {
      result[row.get_name("job_key")] = @json.from_json(
        @json.parse((row.get_name("environment_json") : String)),
      )
    }
    result
  })
}
