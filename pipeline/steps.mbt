///|
pub fn Coordinator::update_step(
  self : Coordinator,
  id : Int64,
  token : String,
  request : @protocol.StepRequest,
) -> @protocol.LeaseState raise {
  check_version(request.version)
  guard ["running", "success", "failure", "timed_out", "cancelled", "skipped"].contains(
      request.state,
    ) &&
    request.exit_code >= -255 &&
    request.exit_code <= 255 else {
    raise @domain.BadRequest(message="invalid step state or exit code")
  }
  guard !(request.state == "success" && request.exit_code != 0) else {
    raise @domain.BadRequest(message="successful step requires exit code zero")
  }
  self.authenticate_attempt(id, token)
  ignore(self.expire_attempts())
  self.pool.with_client(client => {
    client.with_transaction(
      tx => {
        let row = load_live_attempt(tx, id, token, (self.clock)())
        guard (row.get_name("execution_id") : String?) is Some(_) else {
          raise Conflict("execution instance is not bound")
        }
        let step = tx.query_opt(
          "SELECT * FROM pipeline_step WHERE attempt_id = ? AND step_id = ?",
          params=[id, request.step_id],
        )
        guard step is Some(step) else {
          raise @domain.BadRequest(message="unknown step")
        }
        let current : String = step.get_name("state")
        if current == request.state &&
          (step.get_name("exit_code") : Int64) == request.exit_code.to_int64() {
          return lease_state(row, (self.clock)())
        }
        let ordinal : Int64 = step.get_name("ordinal")
        let modern = (row.get_name("definition_version") : Int64) ==
          @workflow.format_version.to_int64()
        if request.state == "running" {
          guard current == "pending" &&
            (row.get_name("status") : String) == "running" &&
            (row.get_name("cancel_at_ms") : Int64?) is None &&
            tx.query_opt(
              if modern {
                "SELECT step_id FROM pipeline_step WHERE attempt_id = ? AND ordinal < ? AND state NOT IN ('success', 'failure', 'skipped') LIMIT 1"
              } else {
                "SELECT step_id FROM pipeline_step WHERE attempt_id = ? AND ordinal < ? AND state <> 'success' LIMIT 1"
              },
              params=[id, ordinal],
            )
            is None else {
            raise Conflict("step cannot start")
          }
        } else if request.state == "skipped" {
          guard (modern && current == "running" && request.exit_code == 0) ||
            (
              current == "pending" &&
              (
                (row.get_name("cancel_at_ms") : Int64?) is Some(_) ||
                tx.query_opt(
                  "SELECT step_id FROM pipeline_step WHERE attempt_id = ? AND ordinal < ? AND state IN ('failure', 'timed_out', 'cancelled', 'lost') LIMIT 1",
                  params=[id, ordinal],
                )
                is Some(_)
              )
            ) else {
            raise Conflict("step cannot be skipped")
          }
        } else {
          guard current == "running" else {
            raise Conflict("step has not started or already ended")
          }
        }
        let _ = tx.execute(
          "UPDATE pipeline_step SET state = ?, exit_code = ? WHERE attempt_id = ? AND step_id = ?",
          params=[
            request.state,
            request.exit_code.to_int64(),
            id,
            request.step_id,
          ],
        )
        lease_state(row, (self.clock)())
      },
      immediate=true,
    )
  })
}

///|
pub fn Coordinator::read_steps(
  self : Coordinator,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  number : Int64,
  id : Int64,
) -> Array[@protocol.StepState] raise {
  let run = get_run(self.pool, actor, repo, number)
  self.pool.with_client(client => {
    guard client.query_opt(
        "SELECT a.id FROM pipeline_job_attempt a JOIN pipeline_job j ON j.id = a.job_id WHERE a.id = ? AND j.run_id = ?",
        params=[id, run.id],
      )
      is Some(_) else {
      raise @domain.NotFound(message="attempt not found")
    }
    client
    .query_all(
      "SELECT * FROM pipeline_step WHERE attempt_id = ? ORDER BY ordinal",
      params=[id],
    )
    .map(row => {
      step_id: row.get_name("step_id"),
      state: row.get_name("state"),
      exit_code: (row.get_name("exit_code") : Int64).to_int(),
    })
  })
}
