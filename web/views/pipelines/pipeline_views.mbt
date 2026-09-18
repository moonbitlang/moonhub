///|
priv struct PipelineJobPage {
  job : @pipeline.JobRun
  steps : Array[@protocol.StepState]
  logs : Array[@protocol.LogChunk]
}

///|
fn pipeline_html(value : String) -> String {
  let out = StringBuilder()
  for ch in value {
    match ch {
      '&' => out.write_string("&amp;")
      '<' => out.write_string("&lt;")
      '>' => out.write_string("&gt;")
      '"' => out.write_string("&quot;")
      '\'' => out.write_string("&#39;")
      _ => out.write_char(ch)
    }
  }
  out.to_string()
}

///|
fn pipeline_run_state(state : @pipeline.RunState) -> String {
  match state {
    @pipeline.Queued => "queued"
    @pipeline.Running => "running"
    @pipeline.Completed => "completed"
  }
}

///|
fn pipeline_job_state(state : @pipeline.JobState) -> String {
  match state {
    @pipeline.Waiting => "waiting"
    @pipeline.Queued => "queued"
    @pipeline.Leased => "leased"
    @pipeline.Running => "running"
    @pipeline.Completed => "completed"
  }
}

///|
fn pipeline_conclusion(value : @pipeline.Conclusion?) -> String {
  match value {
    None => ""
    Some(@pipeline.Success) => "success"
    Some(@pipeline.Failure) => "failure"
    Some(@pipeline.Cancelled) => "cancelled"
    Some(@pipeline.TimedOut) => "timed_out"
    Some(@pipeline.Lost) => "lost"
    Some(@pipeline.Skipped) => "skipped"
  }
}

///|
fn pipeline_result(
  state : @pipeline.RunState,
  conclusion : @pipeline.Conclusion?,
) -> String {
  let conclusion = pipeline_conclusion(conclusion)
  if conclusion.is_empty() {
    pipeline_run_state(state)
  } else {
    conclusion
  }
}

///|
fn render_pipeline_list(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  runs : Array[@pipeline.Run],
  manager : Bool,
) -> @moonback.Html {
  let base = @web_ui.repo_link(scope.repo) + "/pipelines"
  @web_ui.layout(
    "Pipelines",
    assets,
    Html(b => {
      b <+
        "<div class=\"mr-page-heading\"><div><h2>Pipelines</h2><p class=\"muted\">Workflow runs for \{pipeline_html(scope.repo.path())}</p></div>"
      if manager {
        b <+ "<a class=\"button-link\" href=\"\{base}/new\">Run workflow</a>"
      }
      b <+ "</div><ul class=\"mr-list\">"
      for run in runs {
        let result = pipeline_result(run.state, run.conclusion)
        b <+
          "<li><div class=\"mr-list-title\"><a href=\"\{base}/\{run.number.to_string()}\">\{pipeline_html(run.workflow_name)}</a><span class=\"mr-state\" data-state=\"\{result}\">\{result}</span></div><p class=\"muted\">#\{run.number.to_string()} · branch \{pipeline_html(run.source_branch)} · commit <span class=\"path\">\{pipeline_html(run.commit_sha[:12].to_owned())}</span> · \{pipeline_html(run.created_at)}</p></li>"
      }
      if runs.is_empty() {
        b <+ "<li class=\"muted\">No pipeline runs yet.</li>"
      }
      b <+ "</ul>"
    }),
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(scope.repo, "pipelines", manager),
  )
}

///|
fn render_pipeline_form(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  csrf : String,
  branch : String,
  workflow : String,
  error : String?,
) -> @moonback.Html {
  let base = @web_ui.repo_link(scope.repo) + "/pipelines"
  @web_ui.layout(
    "Run workflow",
    assets,
    Html(b => {
      b <+
        "<a href=\"\{base}\">\{pipeline_html(scope.repo.path())} / Pipelines</a><h1>Run workflow</h1>"
      if error is Some(message) {
        b <+
          "<p class=\"flash-error\" role=\"alert\">\{pipeline_html(message)}</p>"
      }
      b <+
        "<form class=\"form-stack\" method=\"post\" action=\"\{base}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label class=\"field\"><span>Branch</span><input name=\"branch\" value=\"\{pipeline_html(branch)}\" required maxlength=\"200\" spellcheck=\"false\"></label><label class=\"field\"><span>Workflow file</span><input name=\"workflow\" value=\"\{pipeline_html(workflow)}\" required maxlength=\"240\" spellcheck=\"false\"></label><div class=\"form-actions\"><button type=\"submit\">Run workflow</button><a href=\"\{base}\">Cancel</a></div></form>"
    }),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(scope.repo, "pipelines", true),
  )
}

///|
fn render_pipeline_detail(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  run : @pipeline.Run,
  jobs : Array[PipelineJobPage],
  manager : Bool,
  csrf : String,
) -> @moonback.Html {
  let base = @web_ui.repo_link(scope.repo) +
    "/pipelines/" +
    run.number.to_string()
  let result = pipeline_result(run.state, run.conclusion)
  @web_ui.layout(
    "Pipeline #\{run.number}",
    assets,
    Html(b => {
      b <+
        "<div class=\"mr-page-heading\"><div><p class=\"muted\"><a href=\"\{@web_ui.repo_link(scope.repo)}/pipelines\">Pipelines</a> / #\{run.number.to_string()}</p><h2>\{pipeline_html(run.workflow_name)}</h2></div><span class=\"mr-state\" data-state=\"\{result}\">\{result}</span></div>"
      b <+
        "<p class=\"muted\">Branch \{pipeline_html(run.source_branch)} · commit <span class=\"path\">\{pipeline_html(run.commit_sha)}</span> · created \{pipeline_html(run.created_at)}</p>"
      if manager {
        b <+ "<div class=\"mr-actions\">"
        if run.state is @pipeline.Queued || run.state is @pipeline.Running {
          b <+
            "<form method=\"post\" action=\"\{base}/cancel\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button class=\"danger-button\" type=\"submit\">Cancel run</button></form>"
        }
        if run.state is @pipeline.Completed {
          b <+
            "<form method=\"post\" action=\"\{base}/rerun\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button type=\"submit\">Rerun snapshot</button></form>"
        }
        b <+ "</div>"
      }
      b <+ "<ol class=\"mr-list\">"
      for page in jobs {
        let state = pipeline_job_state(page.job.state)
        let conclusion = pipeline_conclusion(page.job.conclusion)
        let display = if conclusion.is_empty() { state } else { conclusion }
        b <+
          "<li><div class=\"mr-list-title\"><strong>\{pipeline_html(page.job.job_key)}</strong><span class=\"mr-state\" data-state=\"\{display}\">\{display}</span></div>"
        if !page.steps.is_empty() {
          b <+ "<ul class=\"pipeline-steps\">"
          for step in page.steps {
            b <+
              "<li><span class=\"path\">\{pipeline_html(step.step_id)}</span><span class=\"muted\">exit \{step.exit_code.to_string()}</span> <span class=\"mr-state\" data-state=\"\{step.state}\">\{step.state}</span></li>"
          }
          b <+ "</ul>"
        }
        if !page.logs.is_empty() {
          b <+ "<details class=\"pipeline-logs\"><summary>Logs</summary><pre>"
          for log in page.logs {
            b <+ "\{pipeline_html(log.text)}"
          }
          b <+ "</pre></details>"
        }
        b <+ "</li>"
      }
      b <+ "</ol>"
    }),
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(scope.repo, "pipelines", manager),
  )
}
