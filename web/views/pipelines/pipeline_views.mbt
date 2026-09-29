///|
priv struct PipelineJobPage {
  job : @pipeline.JobRun
  steps : Array[@protocol.StepState]
  logs : @pipeline.LogPage?
  reason : @pipeline.QueueReason?
}

///|
fn queue_reason_text(reason : @pipeline.QueueReason) -> String {
  match reason {
    @pipeline.WaitingDependencies => "Waiting for dependency jobs to succeed."
    @pipeline.RequesterUnavailable =>
      "The requester no longer has permission to run this job, or the repository is not ready."
    @pipeline.NoAuthorizedProvider =>
      "No provider is authorized for this repository."
    @pipeline.NoMatchingLabels =>
      "No authorized provider matches all required job labels."
    @pipeline.ProvidersPaused => "All matching providers are paused."
    @pipeline.ProvidersBusy =>
      "All matching providers are busy with another job."
    @pipeline.NoRecentProviderContact =>
      "No idle matching provider has contacted the server in the last minute."
    @pipeline.AwaitingClaim =>
      "Waiting for an available provider to claim this job."
  }
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
  push_enabled : Bool,
  csrf : String,
  events : Array[@repository.RefEventStatus],
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
      if manager {
        b <+
          "<section class=\"repository-form pipeline-push-settings\"><h2>Automatic workflows</h2><form class=\"form-stack\" method=\"post\" action=\"\{base}/settings\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label><input type=\"checkbox\" name=\"push_enabled\" value=\"1\""
        if push_enabled {
          b <+ " checked"
        }
        b <+
          "> Run push workflows</label><p class=\"settings-notice\">Enables execution of repository code pushed or merged by repository owners and administrators. Provider access and labels still apply.</p><button type=\"submit\"><span class=\"ui-icon\" data-icon=\"check\" aria-hidden=\"true\"></span>Save settings</button></form></section>"
      }
      if !events.is_empty() {
        b <+ "<section><h2>Recent push events</h2><ul class=\"mr-list\">"
        for event in events {
          b <+
            "<li class=\"provider-access-summary\"><span class=\"path\">\{event.reference}</span> <span class=\"muted\">\{event.commit_sha[:12].to_owned()} · \{event.state}</span>"
          if !event.error.is_empty() {
            b <+ "<p class=\"flash-error\">\{event.error}</p>"
          }
          b <+ "</li>"
        }
        b <+ "</ul></section>"
      }
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
  merge : @pipeline.MergeCheckContext?,
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
        "<section data-pipeline-run data-run-url=\"\{base}\" data-run-phase=\"\{pipeline_run_state(run.state)}\"><div class=\"mr-page-heading\"><div><p class=\"muted\"><a href=\"\{@web_ui.repo_link(scope.repo)}/pipelines\">Pipelines</a> / #\{run.number.to_string()}</p><h2>\{pipeline_html(run.workflow_name)}</h2></div><span class=\"mr-state\" data-run-state data-state=\"\{result}\">\{result}</span></div><p class=\"settings-notice\" data-update-error role=\"status\" hidden></p>"
      b <+
        "<p class=\"muted\">Branch \{pipeline_html(run.source_branch)} · commit <span class=\"path\">\{pipeline_html(run.commit_sha)}</span> · created \{pipeline_html(run.created_at)}</p>"
      if merge is Some(merge) {
        b <+
          "<p><a href=\"\{@web_ui.repo_link(scope.repo)}/merge-requests/\{merge.number.to_string()}?version=\{merge.version.to_string()}\">Merge request !\{merge.number.to_string()}, version \{merge.version.to_string()}</a></p><p class=\"muted mr-shas\"><span>Source <code>\{merge.source_sha[:12].to_owned()}</code></span><span>Target <code>\{merge.target_sha[:12].to_owned()}</code></span></p>"
      }
      if manager {
        b <+ "<div class=\"mr-actions\">"
        b <+ "<form data-run-cancel method=\"post\" action=\"\{base}/cancel\""
        if run.state is @pipeline.Completed {
          b <+ " hidden"
        }
        b <+
          "><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button class=\"danger-button\" type=\"submit\">Cancel run</button></form><form data-run-rerun method=\"post\" action=\"\{base}/rerun\""
        if !(run.state is @pipeline.Completed) {
          b <+ " hidden"
        }
        b <+
          "><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button type=\"submit\">Rerun snapshot</button></form>"
        b <+ "</div>"
      }
      b <+ "<ol class=\"mr-list\">"
      for page in jobs {
        let state = pipeline_job_state(page.job.state)
        let conclusion = pipeline_conclusion(page.job.conclusion)
        let display = if conclusion.is_empty() { state } else { conclusion }
        b <+
          "<li data-pipeline-job=\"\{page.job.id.to_string()}\" data-attempt-id=\"\{page.job.attempt_id.map(id => id.to_string()).unwrap_or("")}\"><div class=\"mr-list-title\"><strong>\{pipeline_html(page.job.job_key)}</strong><span class=\"mr-state\" data-job-state data-state=\"\{display}\">\{display}</span></div>"
        b <+ "<p class=\"settings-notice\" data-queue-reason"
        if page.reason is None {
          b <+ " hidden"
        }
        b <+ ">\{page.reason.map(queue_reason_text).unwrap_or("")}</p>"
        if run.definition.jobs
          .iter()
          .find_first(job => job.id == page.job.job_key)
          is Some(definition) {
          b <+ "<p class=\"muted provider-access-summary\" data-required-labels"
          if page.reason is None {
            b <+ " hidden"
          }
          b <+ ">Required labels: \{definition.runs_on.join(", ")}</p>"
        }
        b <+ "<ul class=\"pipeline-steps\" data-job-steps"
        if page.steps.is_empty() {
          b <+ " hidden"
        }
        b <+ ">"
        for step in page.steps {
          b <+
            "<li data-step-id=\"\{step.step_id}\"><span class=\"path\">\{pipeline_html(step.step_id)}</span> <span class=\"muted\" data-step-exit>exit \{step.exit_code.to_string()}</span> <span class=\"mr-state\" data-step-state data-state=\"\{step.state}\">\{step.state}</span></li>"
        }
        b <+ "</ul>"
        let chunks = page.logs.map(logs => logs.chunks).unwrap_or([])
        b <+
          "<details class=\"pipeline-logs\" data-log-cursor=\"\{page.logs.map(logs => logs.next_cursor).unwrap_or("0")}\" data-log-complete=\"\{page.logs.map(logs => logs.complete).unwrap_or(true).to_string()}\" data-log-more=\"\{page.logs.map(logs => logs.has_more).unwrap_or(false).to_string()}\""
        if chunks.is_empty() {
          b <+ " hidden"
        }
        b <+ "><summary>Logs</summary><pre>"
        for log in chunks {
          b <+ "\{log.text}"
        }
        b <+ "</pre></details>"
        b <+ "</li>"
      }
      b <+ "</ol></section>"
    }),
    head_end=Html(b => {
      b <+ "\{@web_assets.repository_assets_head(assets)}"
      let script = @web_assets.vite_manifest_entry_path(
        assets, "src/pipeline-logs.ts",
      )
      b <+ "<script type=\"module\" src=\"\{script}\"></script>"
    }),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(scope.repo, "pipelines", manager),
  )
}
