///|
#derive(ToJson, FromJson)
priv struct DeploymentSnapshot {
  id : Int64
  name : String
  variables : Map[String, String]
}

///|
fn snapshot_deployments(
  tx : @database.DbTransaction,
  repository_id : Int64,
  run_id : Int64,
  rerun_source : Int64,
) -> Unit raise {
  let snapshots : Map[String, DeploymentSnapshot] = Map([])
  let data = if rerun_source != 0L {
    tx
    .query_opt(
      "SELECT data_json FROM pipeline_run_deployment_snapshot WHERE run_id=?",
      params=[rerun_source],
    )
    .map(row => (row.get_name("data_json") : String))
    .unwrap_or("{}")
  } else {
    for
      row in tx.query_all(
        "SELECT id,name FROM repository_deployment_environment WHERE repository_id=? ORDER BY id",
        params=[repository_id],
      ) {
      let id : Int64 = row.get_name("id")
      let name : String = row.get_name("name")
      let variables : Map[String, String] = Map([])
      for
        value in tx.query_all(
          "SELECT name,value FROM deployment_environment_variable WHERE environment_id=?",
          params=[id],
        ) {
        variables[value.get_name("name")] = value.get_name("value")
      }
      guard @utf8.encode(ToJson::to_json(variables).stringify()).length() <=
        262144 else {
        raise @domain.BadRequest(
          message="Environment variable snapshot exceeds 256 KiB.",
        )
      }
      snapshots[name.to_lower()] = { id, name, variables, }
    }
    ToJson::to_json(snapshots).stringify()
  }
  guard @utf8.encode(data).length() <= 1048576 else {
    raise @domain.BadRequest(
      message="Deployment configuration snapshot exceeds 1 MiB.",
    )
  }
  ignore(
    tx.execute(
      "INSERT INTO pipeline_run_deployment_snapshot(run_id,data_json) VALUES(?,?)",
      params=[run_id, data],
    ),
  )
}

///|
fn admit_deployment(
  tx : @database.DbTransaction,
  run : Run,
  job_id : Int64,
  job : @workflow.Job,
  context : Map[String, Json],
) -> Bool raise {
  guard !job.deployment_environment.is_empty() else { return true }
  let current = tx.query_opt(
    "SELECT * FROM pipeline_job_deployment WHERE job_id=?",
    params=[job_id],
  )
  let environment_id : Int64 = if current is Some(row) {
    row.get_name("environment_id")
  } else {
    let name = @workflow.scheduling_template(
      job.deployment_environment,
      context,
      extended=true,
    ).to_lower()
    let url = @workflow.scheduling_template(
      job.deployment_url,
      context,
      extended=true,
    )
    guard url.is_empty() ||
      (
        url.has_prefix("https://") &&
        url.length() <= 2048 &&
        !url
        .iter()
        .any(c => c.to_int() < 32 || c == '"' || c == '<' || c == '>')
      ) else {
      raise @domain.BadRequest(message="Deployment URL must be an HTTPS URL.")
    }
    let data : Map[String, DeploymentSnapshot] = @json.from_json(
      @json.parse(
        (
          tx
          .query_one(
            "SELECT data_json FROM pipeline_run_deployment_snapshot WHERE run_id=?",
            params=[run.id],
          )
          .get_name("data_json") : String),
      ),
    )
    guard data.get(name) is Some(saved) else {
      raise @domain.BadRequest(
        message="Deployment environment is absent from the saved run configuration.",
      )
    }
    ignore(
      tx.execute(
        "INSERT INTO pipeline_job_deployment(job_id,environment_id,name,url,policy_version,state,variables_json) VALUES(?,?,?,?,0,'pending',?)",
        params=[
          job_id,
          saved.id,
          saved.name,
          url,
          ToJson::to_json(saved.variables).stringify(),
        ],
      ),
    )
    saved.id
  }
  ignore(
    deployment_variables(
      tx,
      job_id,
      run.context.map(ctx => ctx.variables).unwrap_or(Map([])),
    ),
  )
  let policy = tx.query_opt(
    "SELECT version,reviewers_json FROM repository_deployment_environment WHERE id=? AND repository_id=?",
    params=[environment_id, run.repository_id],
  )
  guard policy is Some(policy) else {
    raise @domain.BadRequest(
      message="Saved deployment environment is no longer available.",
    )
  }
  let version : Int64 = policy.get_name("version")
  let reviewers : Array[Int64] = @json.from_json(
    @json.parse((policy.get_name("reviewers_json") : String)),
  )
  ignore(
    tx.execute(
      "UPDATE pipeline_job_deployment SET policy_version=?,state=? WHERE job_id=? AND policy_version<>?",
      params=[
        version,
        if reviewers.is_empty() {
          "approved"
        } else {
          "pending"
        },
        job_id,
        version,
      ],
    ),
  )
  if (
      tx
      .query_one("SELECT state FROM pipeline_job_deployment WHERE job_id=?", params=[
        job_id,
      ])
      .get_name("state") : String) ==
    "rejected" {
    raise @domain.BadRequest(message="Deployment was rejected.")
  }
  let admitted = tx.query_opt(
      "SELECT job_id FROM pipeline_deployment_admission WHERE job_id=?",
      params=[job_id],
    )
    is Some(_)
  if !admitted {
    ignore(
      tx.execute(
        "UPDATE pipeline_job_deployment SET state='pending' WHERE job_id=? AND state='approved'",
        params=[job_id],
      ),
    )
  }
  admitted
}

///|
fn deployment_authorized(
  tx : @database.DbTransaction,
  job_id : Int64,
) -> Bool raise {
  tx.query_opt("SELECT job_id FROM pipeline_job_deployment WHERE job_id=?", params=[
    job_id,
  ])
  is None ||
  tx.query_opt(
    "SELECT job_id FROM pipeline_deployment_admission WHERE job_id=?",
    params=[job_id],
  )
  is Some(_)
}

///|
fn deployment_variables(
  tx : @database.DbTransaction,
  job_id : Int64,
  base : Map[String, String],
) -> Map[String, String] raise {
  let values = base.copy()
  if tx.query_opt(
      "SELECT variables_json FROM pipeline_job_deployment WHERE job_id=?",
      params=[job_id],
    )
    is Some(row) {
    let saved : Map[String, String] = @json.from_json(
      @json.parse((row.get_name("variables_json") : String)),
    )
    for key, value in saved {
      values[key] = value
    }
  }
  guard values.length() <= 500 &&
    @utf8.encode(ToJson::to_json(values).stringify()).length() <= 262144 else {
    raise @domain.BadRequest(
      message="Combined repository and environment variables exceed 500 values or 256 KiB.",
    )
  }
  values
}

///|
#derive(Debug, ToJson)
pub struct JobDeployment {
  job_id : Int64
  job_key : String
  environment_id : Int64
  name : String
  url : String
  policy_version : Int64
  state : String
  can_review : Bool
  reviews : Array[Json]
}

///|
pub fn job_deployments(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
) -> Array[JobDeployment] raise {
  let run = get_run(pool, actor, repo, number)
  pool.with_client(client => {
    client
    .query_all(
      "SELECT d.*,j.id AS current_job_id,j.job_key,e.reviewers_json,e.version AS current_version,j.status AS job_status,EXISTS (SELECT 1 FROM user u JOIN repository repo ON repo.id=? LEFT JOIN team_member tm ON tm.team_id=repo.team_id AND tm.user_id=u.id WHERE u.id=? AND u.status='active' AND (u.is_site_admin=1 OR tm.role IN ('owner','admin','member'))) AS reviewer_access FROM pipeline_job j LEFT JOIN pipeline_job_reuse reuse ON reuse.job_id=j.id JOIN pipeline_job_deployment d ON d.job_id=COALESCE(reuse.source_job_id,j.id) LEFT JOIN repository_deployment_environment e ON e.id=d.environment_id WHERE j.run_id=? ORDER BY j.ordinal",
      params=[run.repository_id, actor.id, run.id],
    )
    .map(row => {
      let job_id : Int64 = row.get_name("job_id")
      let reviewers : Array[Int64] = @json.from_json(
        @json.parse((row.get_name("reviewers_json") : String?).unwrap_or("[]")),
      )
      let version : Int64 = row.get_name("policy_version")
      let state : String = row.get_name("state")
      let reviews = client
        .query_all(
          "SELECT actor_id,decision,policy_version,created_at FROM pipeline_deployment_review WHERE job_id=? ORDER BY id",
          params=[job_id],
        )
        .map(review => {
          (
            {
              "actor_id": ToJson::to_json(
                (review.get_name("actor_id") : Int64?),
              ),
              "decision": (review.get_name("decision") : String),
              "policy_version": (review.get_name("policy_version") : Int64).to_string(),
              "created_at": (review.get_name("created_at") : String),
            } : Json)
        })
      {
        job_id: row.get_name("current_job_id"),
        job_key: row.get_name("job_key"),
        environment_id: row.get_name("environment_id"),
        name: row.get_name("name"),
        url: row.get_name("url"),
        policy_version: version,
        state,
        can_review: state == "pending" &&
        (row.get_name("job_status") : String) == "waiting" &&
        (row.get_name("reviewer_access") : Bool) &&
        reviewers.contains(actor.id) &&
        (row.get_name("current_version") : Int64?) == Some(version),
        reviews,
      }
    })
  })
}

///|
pub fn Coordinator::review_deployment(
  self : Coordinator,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
  job_id : Int64,
  environment_id : Int64,
  policy_version : Int64,
  decision : String,
) -> Unit raise {
  let run = get_run(self.pool, actor, repo, number)
  guard ["approved", "rejected"].contains(decision) else {
    raise @domain.BadRequest(message="Choose approved or rejected.")
  }
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = tx.query_opt(
          "SELECT d.*,e.reviewers_json,e.version AS current_version,j.status FROM pipeline_job_deployment d JOIN pipeline_job j ON j.id=d.job_id JOIN repository_deployment_environment e ON e.id=d.environment_id WHERE d.job_id=? AND j.run_id=? AND e.repository_id=?",
          params=[job_id, run.id, run.repository_id],
        )
        guard row is Some(row) &&
          (row.get_name("environment_id") : Int64) == environment_id &&
          (row.get_name("policy_version") : Int64) == policy_version &&
          (row.get_name("current_version") : Int64) == policy_version else {
          raise Conflict(
            "Deployment or policy changed; reload before reviewing.",
          )
        }
        let reviewers : Array[Int64] = @json.from_json(
          @json.parse((row.get_name("reviewers_json") : String)),
        )
        guard reviewers.contains(actor.id) &&
          tx.query_opt(
            "SELECT u.id FROM user u JOIN repository r ON r.id=? LEFT JOIN team_member tm ON tm.team_id=r.team_id AND tm.user_id=u.id WHERE u.id=? AND u.status='active' AND (u.is_site_admin=1 OR tm.role IN ('owner','admin','member'))",
            params=[run.repository_id, actor.id],
          )
          is Some(_) else {
          raise @domain.Forbidden(
            message="An authorized environment reviewer is required.",
          )
        }
        if (row.get_name("state") : String) == decision &&
          tx.query_opt(
            "SELECT id FROM pipeline_deployment_review WHERE job_id=? AND policy_version=? AND actor_id=? AND decision=?",
            params=[job_id, policy_version, actor.id, decision],
          )
          is Some(_) {
          return
        }
        guard (row.get_name("state") : String) == "pending" &&
          (row.get_name("status") : String) == "waiting" else {
          raise Conflict("This deployment is no longer pending review.")
        }
        ignore(
          tx.execute(
            "INSERT INTO pipeline_deployment_review(job_id,environment_id,policy_version,actor_id,decision) VALUES(?,?,?,?,?)",
            params=[job_id, environment_id, policy_version, actor.id, decision],
          ),
        )
        ignore(
          tx.execute(
            "UPDATE pipeline_job_deployment SET state=? WHERE job_id=?",
            params=[decision, job_id],
          ),
        )
        advance_run_jobs(tx, run.id)
        finalize_run(tx, run.id)
      },
      immediate=true,
    )
  })
}
