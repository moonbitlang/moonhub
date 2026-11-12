///|
pub fn set_scheduled_runs(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  enabled : Bool,
) -> Unit raise {
  let scope = require_run_author(pool, actor, repo)
  pool.with_client(c => {
    ignore(
      c.execute(
        "INSERT INTO pipeline_schedule_config(repository_id,actor_id,enabled) VALUES(?,?,?) ON CONFLICT(repository_id) DO UPDATE SET actor_id=excluded.actor_id,enabled=excluded.enabled,last_error=''",
        params=[scope.id, actor.id, enabled],
      ),
    )
  })
}

///|
pub fn scheduled_runs_status(
  pool : @database.Database,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
) -> (Bool, String) raise {
  let scope = require_run_author(pool, actor, repo)
  pool.with_client(c => {
    match
      c.query_opt(
        "SELECT enabled,last_error FROM pipeline_schedule_config WHERE repository_id=?",
        params=[scope.id],
      ) {
      None => (false, "")
      Some(row) => (row.get_name("enabled"), row.get_name("last_error"))
    }
  })
}

///|
pub async fn run_due_schedules(
  pool : @database.Database,
  root : String,
  now_ms~ : Int64 = @env.now().reinterpret_as_int64(),
) -> Unit {
  let minute = now_ms / 60000L
  let utc = pool.with_client(c => {
    c.query_one(
      "SELECT CAST(strftime('%M',?/1000,'unixepoch') AS INTEGER) minute,CAST(strftime('%H',?/1000,'unixepoch') AS INTEGER) hour,CAST(strftime('%d',?/1000,'unixepoch') AS INTEGER) day,CAST(strftime('%m',?/1000,'unixepoch') AS INTEGER) month,CAST(strftime('%w',?/1000,'unixepoch') AS INTEGER) weekday",
      params=[now_ms, now_ms, now_ms, now_ms, now_ms],
    )
  })
  let rows = pool.with_client(c => {
    c.query_all(
      "SELECT s.*,r.default_branch,r.name,t.name_key owner,u.name_key actor FROM pipeline_schedule_config s JOIN repository r ON r.id=s.repository_id JOIN team t ON t.id=r.team_id JOIN user u ON u.id=s.actor_id WHERE s.enabled=1 AND r.ready=1 AND u.status='active' AND s.polled_minute<? ORDER BY s.polled_minute,s.repository_id LIMIT 20",
      params=[minute],
    )
  })
  for row in rows {
    let repo : @domain.RepoId = {
      owner: row.get_name("owner"),
      name: row.get_name("name"),
    }
    let id : Int64 = row.get_name("repository_id")
    let mut failed = false
    try {
      let actor = @identity.active_user_by_name(pool, row.get_name("actor"))
      ignore(require_run_author(pool, actor, repo))
      let branch : String = row.get_name("default_branch")
      let sha = @gitops.branch_sha(repo.git_dir(root), branch)
      let output = @gitops.merge_git(repo.git_dir(root), [
        "ls-tree", sha, ".github/workflows/",
      ])
      let paths = @domain.split_lines(output)
        .iter()
        .filter_map(line => line.split_once("\t").map(p => p.1.to_owned()))
        .filter(p => p.has_suffix(".yml") || p.has_suffix(".yaml"))
        .collect()
      guard paths.length() <= 64 else {
        raise @domain.BadRequest(message="too many scheduled workflows")
      }
      for path in paths {
        try {
          let source = read_workflow_source(repo.git_dir(root), sha, path)
          let triggers = @workflow.triggers(source)
          let due = triggers.schedules.any(cron => {
            @workflow.cron_matches(
              cron,
              (utc.get_name("minute") : Int64).to_int(),
              (utc.get_name("hour") : Int64).to_int(),
              (utc.get_name("day") : Int64).to_int(),
              (utc.get_name("month") : Int64).to_int(),
              (utc.get_name("weekday") : Int64).to_int(),
            )
          })
          if due {
            ignore(
              create_run_event(
                pool,
                root,
                actor,
                repo,
                branch,
                path,
                scheduled_minute=minute,
              ),
            )
          }
        } catch {
          _ => failed = true
        }
      }
    } catch {
      _ => failed = true
    }
    pool.with_client(c => {
      ignore(
        c.execute(
          "UPDATE pipeline_schedule_config SET polled_minute=?,last_error=? WHERE repository_id=?",
          params=[
            minute,
            if failed {
              "One or more scheduled workflows could not run. Check workflow validation and runner access."
            } else {
              ""
            },
            id,
          ],
        ),
      )
    })
  }
}
