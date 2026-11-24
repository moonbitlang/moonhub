///|
// A group-only selector can choose any OS. Bind the actual provider OS into
// the assignment so native validation and runner.os agree on the selected pool.
fn runner_group_labels(
  tx : @database.DbTransaction,
  job : @workflow.Job,
  provider : Int64,
) -> Array[String] raise {
  if job.runner_group.is_empty() ||
    job.runs_on.any(label => ["linux", "windows", "macos"].contains(label)) {
    return job.runs_on
  }
  let labels = job.runs_on.copy()
  for
    row in tx.query_all(
      "SELECT label FROM pipeline_provider_label WHERE provider_id=? AND label IN ('linux','windows','macos')",
      params=[provider],
    ) {
    labels.push(row.get_name("label"))
  }
  labels
}

///|
pub struct RunnerGroup {
  name : String
  revision : Int64
  providers : Array[Int64]
  repositories : Array[String]
}

///|
pub fn Coordinator::runner_groups(
  self : Coordinator,
  actor : @domain.CurrentUser,
) -> Array[RunnerGroup] raise {
  require_provider_admin(self.pool, actor)
  self.pool.with_client(client => {
    client
    .query_all(
      "SELECT id,name,revision FROM pipeline_runner_group ORDER BY name",
    )
    .map(row => {
      let id : Int64 = row.get_name("id")
      {
        name: row.get_name("name"),
        revision: row.get_name("revision"),
        providers: client
        .query_all(
          "SELECT provider_id FROM pipeline_runner_group_provider WHERE group_id=? ORDER BY provider_id",
          params=[id],
        )
        .map(entry => entry.get_name("provider_id")),
        repositories: client
        .query_all(
          "SELECT t.name_key || '/' || r.name AS name FROM pipeline_runner_group_repository g JOIN repository r ON r.id=g.repository_id JOIN team t ON t.id=r.team_id WHERE g.group_id=? ORDER BY name",
          params=[id],
        )
        .map(grant_ => grant_.get_name("name")),
      }
    })
  })
}

///|
pub fn Coordinator::save_runner_group(
  self : Coordinator,
  actor : @domain.CurrentUser,
  name : String,
  revision : Int64,
  providers : Array[Int64],
  repositories : Array[@domain.RepoId],
) -> Unit raise {
  require_provider_admin(self.pool, actor)
  let name = name.to_lower()
  guard name.length() <= 64 &&
    name.get_char(0) is Some(first) &&
    (first.is_ascii_alphabetic() || first == '_') &&
    name
    .iter()
    .all(ch => {
      ch.is_ascii_alphabetic() || ch.is_ascii_digit() || ch == '-' || ch == '_'
    }) &&
    providers.length() <= 100 &&
    repositories.length() <= 100 else {
    raise @domain.BadRequest(
      message="Use a runner group name of 1-64 letters, digits, hyphens or underscores, starting with a letter or underscore, and at most 100 providers and repositories.",
    )
  }
  let repo_ids = repositories.map(repo => {
    @repository.repository_scope(self.pool, actor, repo).id
  })
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let previous = tx.query_opt(
          "SELECT id,revision FROM pipeline_runner_group WHERE name=?",
          params=[name],
        )
        let id : Int64 = match previous {
          Some(row) => {
            guard (row.get_name("revision") : Int64) == revision else {
              raise Conflict("Runner group changed. Reload before saving.")
            }
            row.get_name("id")
          }
          None => {
            guard revision == 0L else {
              raise Conflict("Runner group changed. Reload before saving.")
            }
            guard (
                tx
                .query_one(
                  "SELECT COUNT(*) AS count FROM pipeline_runner_group",
                )
                .get_name("count") : Int64) <
              100L else {
              raise @domain.BadRequest(
                message="At most 100 runner groups are supported.",
              )
            }
            tx
            .query_one(
              "INSERT INTO pipeline_runner_group(name) VALUES(?) RETURNING id",
              params=[name],
            )
            .get_name("id")
          }
        }
        for provider in providers {
          guard tx.query_opt(
              "SELECT id FROM pipeline_provider WHERE id=? AND revoked=0",
              params=[provider],
            )
            is Some(_) else {
            raise @domain.BadRequest(
              message="Select active registered providers.",
            )
          }
        }
        ignore(
          tx.execute(
            "DELETE FROM pipeline_runner_group_provider WHERE group_id=?",
            params=[id],
          ),
        )
        ignore(
          tx.execute(
            "DELETE FROM pipeline_runner_group_repository WHERE group_id=?",
            params=[id],
          ),
        )
        for provider in providers {
          ignore(
            tx.execute(
              "INSERT OR IGNORE INTO pipeline_runner_group_provider(group_id,provider_id) VALUES(?,?)",
              params=[id, provider],
            ),
          )
        }
        for repo in repo_ids {
          ignore(
            tx.execute(
              "INSERT OR IGNORE INTO pipeline_runner_group_repository(group_id,repository_id) VALUES(?,?)",
              params=[id, repo],
            ),
          )
        }
        if previous is Some(_) {
          ignore(
            tx.execute(
              "UPDATE pipeline_runner_group SET revision=revision+1 WHERE id=?",
              params=[id],
            ),
          )
        }
        // Credentials become unusable immediately. Existing execution retains its
        // worker slot until the established cancellation/fencing path finishes.
        ignore(
          tx.execute(
            "UPDATE pipeline_job_attempt SET cancel_at_ms=COALESCE(cancel_at_ms,?) WHERE status<>'completed' AND job_id IN (SELECT job_id FROM pipeline_job_runner_group WHERE group_name=?) AND NOT EXISTS (SELECT 1 FROM pipeline_provider_job_group allowed WHERE allowed.job_id=pipeline_job_attempt.job_id AND allowed.provider_id=pipeline_job_attempt.provider_id)",
            params=[(self.clock)(), name],
          ),
        )
      },
      immediate=true,
    )
  })
}
