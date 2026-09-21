///|
let pipeline_updates_module : @moonback.Module = Module(ctx => {
  let pool = ctx.require(@web_context.config_db_pool)
  let coordinator = ctx.require(@web_context.pipeline_coordinator_key)
  ctx.get("/:owner/:repo/pipelines/:number/updates", async fn(req, res) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let number = pipeline_number(req)
    let run = @pipeline.get_run(pool, actor, repo, number)
    let reasons = coordinator.queue_reasons(actor, repo, number)
    let jobs = @pipeline.list_jobs(pool, actor, repo, number).map(job => {
      let steps = match job.attempt_id {
        Some(id) => coordinator.read_steps(actor, repo, number, id)
        None => []
      }
      let state = pipeline_job_state(job.state)
      let conclusion = pipeline_conclusion(job.conclusion)
      let json : Json = {
        "id": job.id.to_string(),
        "attempt_id": job.attempt_id.map(id => id.to_string()).unwrap_or(""),
        "state": state,
        "result": if conclusion.is_empty() {
          state
        } else {
          conclusion
        },
        "reason": reasons.get(job.job_key).map(queue_reason_text).unwrap_or(""),
        "steps": ToJson::to_json(steps),
      }
      json
    })
    res.send_json(
      {
        "state": pipeline_run_state(run.state),
        "result": pipeline_result(run.state, run.conclusion),
        "jobs": ToJson::to_json(jobs),
      },
      headers=@web_context.private_page_headers(),
    )
  })
  ctx.get("/:owner/:repo/pipelines/:number/attempts/:attempt/logs", async fn(
    req,
    res,
  ) {
    let actor = @web_context.require_current_user(req)
    let repo = @web_context.repo_param(req)
    let number = pipeline_number(req)
    let attempt = @web_context.positive_resource_number(
      @web_context.required_param(req, "attempt", "job attempt"),
    )
    guard @protocol.parse_decimal(req.query().get("after").unwrap_or("0"))
      is Some(after) else {
      raise @domain.BadRequest(message="invalid log cursor")
    }
    let page = coordinator.read_log_page(actor, repo, number, attempt, after~)
    res.send_json(
      {
        "chunks": ToJson::to_json(page.chunks),
        "next_cursor": page.next_cursor,
        "has_more": page.has_more,
        "complete": page.complete,
      },
      headers=@web_context.private_page_headers(),
    )
  })
})
