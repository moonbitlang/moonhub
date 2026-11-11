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
    @pipeline.WaitingConcurrency =>
      "Waiting for the previous run in this concurrency group to finish."
    @pipeline.WaitingMatrixCapacity =>
      "Waiting for an available matrix parallel slot."
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
  events : Array[@pipeline.TriggerEvent],
  tab : String,
  page : Int64,
  status : String,
  branch : String,
  workflow : String,
  saved : Bool,
) -> @moonback.Html {
  let base = @web_ui.repo_link(scope.repo) + "/pipelines"
  @web_ui.layout(
    "Pipelines",
    assets,
    Html(b => {
      b <+
        "<div class=\"page-heading page-heading--actions\"><div><h1>Pipelines</h1><p class=\"page-subtitle\">\{scope.repo.path()} · Workflow execution and triggers</p></div>"
      if manager && tab == "runs" {
        b <+ "<a class=\"button-link\" href=\"\{base}/new\">Run workflow</a>"
      }
      b <+ "</div><nav class=\"page-tabs\" aria-label=\"Pipeline views\">"
      for
        (key, label) in [
          ("runs", "Runs"),
          ("events", "Trigger events"),
          ("settings", "Settings"),
        ] {
        if key == "settings" && !manager {
          continue
        }
        b <+ "<a href=\"\{base}?tab=\{key}\""
        if tab == key {
          b <+ " aria-current=\"page\""
        }
        b <+ ">\{label}</a>"
      }
      b <+ "</nav>"
      if tab == "settings" {
        b <+
          "<section class=\"bounded-section\"><h2>Automatic workflows</h2><p class=\"muted\">Choose whether repository owners and administrators can trigger workflows by pushing code.</p>"
        if saved {
          b <+
            "<p class=\"settings-success\" role=\"status\">Pipeline settings saved.</p>"
        }
        b <+
          "<form class=\"form-stack\" method=\"post\" action=\"\{base}/settings\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><label class=\"checkbox-field\"><input type=\"checkbox\" name=\"push_enabled\" value=\"1\""
        if push_enabled {
          b <+ " checked"
        }
        b <+
          "><span>Run push workflows</span></label><p class=\"muted\">Provider access and matching job labels still apply. Provider administration is managed separately at site level.</p><div><button type=\"submit\">Save settings</button></div></form></section>"
      } else if tab == "events" {
        b <+
          "<p class=\"page-subtitle\">Why a push did or did not start a workflow. Trigger diagnostics are separate from run results.</p><ul class=\"event-list\">"
        for event in events {
          b <+
            "<li><div class=\"record-title\"><code>\{event.reference}</code><span class=\"muted\">\{event.state}</span></div><p><a class=\"path\" href=\"\{@web_ui.repo_link(scope.repo)}/commit/\{event.commit_sha}\">\{event.commit_sha[:12].to_owned()}</a> · <a href=\"\{base}?tab=runs&amp;branch=\{@web_context.url_escape_path(event.reference.strip_prefix("refs/heads/").unwrap_or(event.reference).to_owned())}\">View branch runs</a></p>"
          b <+
            "<time datetime=\"\{event.created_at}\" title=\"\{event.created_at} UTC\" data-relative-time>\{event.created_at} UTC</time>"
          for run in event.runs {
            let result = pipeline_result(run.state, run.conclusion)
            b <+
              "<p><a href=\"\{base}/\{run.number.to_string()}\">#\{run.number.to_string()} · \{run.workflow_name}</a> <span class=\"mr-state\" data-state=\"\{result}\">\{pipeline_display_state(result)}</span></p>"
          }
          if event.runs.is_empty() && event.state == "processed" {
            b <+
              "<p class=\"muted\">No workflow run was created for this event.</p>"
          }
          if !event.error.is_empty() {
            b <+
              "<details class=\"event-diagnostic\"><summary>Workflow trigger diagnostics</summary><p>\{event.error}</p></details>"
          }
          b <+ "</li>"
        }
        if events.is_empty() {
          b <+
            "<li class=\"empty-state\"><h2>No trigger events yet</h2><p>Push events appear here when automatic workflows are enabled and an authorized member pushes code.</p></li>"
        }
        b <+ "</ul>"
      } else {
        b <+
          "<form class=\"list-filters\" method=\"get\"><input type=\"hidden\" name=\"tab\" value=\"runs\"><label class=\"field\"><span>Status</span><select name=\"status\">"
        for
          (key, label) in [
            ("", "All statuses"),
            ("running", "Running"),
            ("queued", "Queued"),
            ("success", "Passed"),
            ("failure", "Failed"),
            ("cancelled", "Cancelled"),
            ("timed_out", "Timed out"),
            ("lost", "Runner lost"),
          ] {
          b <+ "<option value=\"\{key}\""
          if key == status {
            b <+ " selected"
          }
          b <+ ">\{label}</option>"
        }
        b <+
          "</select></label><label class=\"field\"><span>Branch</span><input name=\"branch\" value=\"\{branch}\" placeholder=\"All branches\"></label><label class=\"field\"><span>Workflow file</span><input name=\"workflow\" value=\"\{workflow}\" placeholder=\"All workflows\"></label><button class=\"secondary-button\" type=\"submit\">Filter</button><a href=\"\{base}\">Reset</a></form><ul class=\"run-list\">"
        for i, run in runs {
          if i >= 50 {
            break
          }
          let result = pipeline_result(run.state, run.conclusion)
          b <+
            "<li><div class=\"run-identity\"><span class=\"mr-state\" data-state=\"\{result}\">\{pipeline_display_state(result)}</span><div><a class=\"record-title\" href=\"\{base}/\{run.number.to_string()}\">#\{run.number.to_string()} · \{run.workflow_name}</a><p class=\"record-meta\"><span>\{run.source_branch}</span><a class=\"path\" href=\"\{@web_ui.repo_link(scope.repo)}/commit/\{run.commit_sha}\">\{run.commit_sha[:12].to_owned()}</a></p></div></div><time data-relative-time datetime=\"\{run.created_at}Z\" title=\"\{run.created_at} UTC\">\{run.created_at} UTC</time></li>"
        }
        if runs.is_empty() {
          b <+
            "<li class=\"empty-state\"><h2>\{if status.is_empty() && branch.is_empty() && workflow.is_empty() { "No pipeline runs yet" } else { "No matching runs" }}</h2><p>\{if status.is_empty() && branch.is_empty() && workflow.is_empty() { "Run a workflow or push code to an enabled workflow to get started." } else { "Change your filters or reset them to see all runs." }}</p></li>"
        }
        b <+
          "</ul><nav class=\"pagination\" aria-label=\"Pipeline pagination\">"
        let filters = "tab=runs&status=" +
          @web_context.url_escape_path(status) +
          "&branch=" +
          @web_context.url_escape_path(branch) +
          "&workflow=" +
          @web_context.url_escape_path(workflow)
        if page > 1L {
          b <+
            "<a href=\"\{base}?\{filters}&amp;page=\{(page - 1L).to_string()}\">Newer runs</a>"
        }
        if runs.length() > 50 {
          b <+
            "<a href=\"\{base}?\{filters}&amp;page=\{(page + 1L).to_string()}\">Older runs</a>"
        }
        b <+ "</nav>"
      }
    }),
    head_end=@web_assets.repository_assets_head(assets),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(scope.repo, "pipelines", manager),
  )
}

///|
fn pipeline_display_state(value : String) -> String {
  match value {
    "success" => "Passed"
    "failure" => "Failed"
    "timed_out" => "Timed out"
    "lost" => "Runner lost"
    "leased" => "Preparing"
    _ => value
  }
}

///|
fn render_pipeline_form(
  assets : Map[String, String],
  user : @domain.CurrentUser,
  scope : @repository.RepositoryScope,
  csrf : String,
  choices : @pipeline.DispatchChoices,
  workflow : String,
  values : Map[String, String],
  error : String?,
) -> @moonback.Html {
  let base = @web_ui.repo_link(scope.repo) + "/pipelines"
  let available = choices.workflows.filter(choice => choice.reason.is_empty())
  let selected = if available.any(choice => choice.path == workflow) {
    workflow
  } else {
    available.get(0).map(choice => choice.path).unwrap_or("")
  }
  let selected_choice = available
    .iter()
    .find_first(choice => choice.path == selected)
  @web_ui.layout(
    "Run workflow",
    assets,
    Html(b => {
      b <+
        "<a class=\"back-link\" href=\"\{base}\">Back to pipelines</a><div class=\"page-heading\"><div><h1>Run workflow</h1><p class=\"page-subtitle\">Select a branch, then a workflow available on that revision.</p></div></div>"
      if error is Some(message) {
        b <+ "<p class=\"flash-error\" role=\"alert\">\{message}</p>"
      }
      b <+
        "<section class=\"bounded-section\"><form class=\"form-stack\" method=\"get\" action=\"\{base}/new\" data-auto-submit><label class=\"field\"><span>Branch</span><select aria-label=\"Branch\" name=\"branch\" required>"
      for branch in choices.branches {
        b <+ "<option value=\"\{branch}\""
        if choices.branch == branch {
          b <+ " selected"
        }
        b <+ ">\{branch}</option>"
      }
      if !choices.branch.is_empty() &&
        !choices.branches.contains(choices.branch) {
        b <+
          "<option selected value=\"\{choices.branch}\">\{choices.branch} — unavailable</option>"
      }
      b <+ "</select></label>"
      if !available.is_empty() {
        b <+
          "<label class=\"field\"><span>Workflow</span><select aria-label=\"Workflow\" name=\"workflow\" required>"
        for choice in available {
          b <+ "<option value=\"\{choice.path}\""
          if choice.path == selected {
            b <+ " selected"
          }
          b <+ ">\{choice.name} · \{choice.path}</option>"
        }
        b <+ "</select></label>"
      }
      b <+
        "<button class=\"secondary-button no-js-submit\" type=\"submit\">Load workflows and inputs</button></form>"
      if choices.commit.is_empty() {
        b <+
          "<div class=\"empty-state\"><h2>\{if choices.branch.is_empty() { "No branches with commits" } else { "Selected branch is unavailable" }}</h2><p>\{if choices.branch.is_empty() { "Push a commit before running a workflow." } else { "Choose another branch to reload available workflows." }}</p></div>"
      } else {
        b <+
          "<p class=\"record-meta\">Revision <a class=\"path\" href=\"\{@web_ui.repo_link(scope.repo)}/commit/\{choices.commit}\">\{choices.commit[:12].to_owned()}</a>. The branch is checked again when the run is created.</p>"
        if available.is_empty() {
          b <+
            "<div class=\"empty-state\"><h2>No manually runnable workflows</h2><p>Add workflow_dispatch to a valid workflow, or select another branch.</p></div>"
        } else {
          b <+
            "<form class=\"form-stack\" method=\"post\" action=\"\{base}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"branch\" value=\"\{choices.branch}\"><input type=\"hidden\" name=\"workflow\" value=\"\{selected}\">"
          if selected_choice is Some(choice) {
            b <+ "<label class=\"field\"><span>Job</span><select name=\"job\">"
            if choice.dispatch {
              b <+ "<option value=\"\">All workflow jobs</option>"
            }
            for id in choice.jobs {
              b <+ "<option value=\"\{id}\""
              if values.get("__job") == Some(id) {
                b <+ " selected"
              }
              b <+ ">\{id}</option>"
            }
            b <+
              "</select><span class=\"muted\">Selected jobs include their dependencies. The original workflow and source commit are saved unchanged.</span></label>"
            for input in choice.inputs {
              let name = input.name
              let default_value = match input.default {
                Some(String(text)) => text
                Some(value) => value.stringify()
                None =>
                  match input.kind {
                    "boolean" => "false"
                    "number" => if input.required { "" } else { "0" }
                    "choice" => input.options.get(0).unwrap_or("")
                    _ => ""
                  }
              }
              let value = values.get(name).unwrap_or(default_value)
              b <+ "<label class=\"field\"><span>\{name}"
              if input.required {
                b <+ " (required)"
              }
              b <+ "</span>"
              if input.kind == "boolean" || input.kind == "choice" {
                let options = if input.kind == "boolean" {
                  ["false", "true"]
                } else {
                  input.options
                }
                b <+ "<select name=\"input:\{name}\""
                if input.required {
                  b <+ " required"
                }
                b <+ ">"
                if !options.contains(value) {
                  b <+
                    "<option value=\"\{value}\" selected>\{value} (invalid)</option>"
                }
                for option in options {
                  b <+ "<option value=\"\{option}\""
                  if option == value {
                    b <+ " selected"
                  }
                  b <+ ">\{option}</option>"
                }
                b <+ "</select>"
              } else {
                b <+ "<input name=\"input:\{name}\" value=\"\{value}\""
                if input.kind == "number" {
                  let parsed = @json.parse(value.trim()) catch {
                    _ => Json::null()
                  }
                  if value.is_empty() ||
                    (
                      parsed is Number(number, ..) &&
                      !number.is_nan() &&
                      !number.is_inf()
                    ) {
                    b <+ " type=\"number\" step=\"any\""
                  } else {
                    b <+
                      " type=\"text\" inputmode=\"decimal\" aria-invalid=\"true\""
                  }
                }
                if input.required {
                  b <+ " required"
                }
                b <+ ">"
              }
              if !input.description.is_empty() {
                b <+ "<span class=\"muted\">\{input.description}</span>"
              }
              b <+ "</label>"
            }
          }
          b <+
            "<div class=\"form-actions\"><button type=\"submit\">Run workflow</button><a href=\"\{base}\">Cancel</a></div></form>"
        }
        if choices.workflows.any(choice => !choice.reason.is_empty()) {
          b <+
            "<details class=\"secondary-details\"><summary>Unavailable workflows</summary><ul>"
          for choice in choices.workflows {
            if !choice.reason.is_empty() {
              b <+ "<li><code>\{choice.path}</code><p>\{choice.reason}</p></li>"
            }
          }
          b <+ "</ul></details>"
        }
      }
      b <+ "</section>"
    }),
    head_end=@web_assets.repository_assets_head(assets),
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
    "Pipeline #\{run.number.to_string()}",
    assets,
    Html(b => {
      b <+
        "<section data-pipeline-run data-run-url=\"\{base}\" data-run-phase=\"\{pipeline_run_state(run.state)}\"><div class=\"mr-page-heading\"><div><p class=\"muted\"><a href=\"\{@web_ui.repo_link(scope.repo)}/pipelines\">Pipelines</a> / #\{run.number.to_string()}</p><h1>\{pipeline_html(run.workflow_name)}</h1></div><span class=\"mr-state\" data-run-state data-state=\"\{result}\">\{pipeline_display_state(result)}</span></div><p class=\"settings-notice\" data-update-error role=\"status\" hidden></p>"
      b <+
        "<p class=\"muted\">Branch \{pipeline_html(run.source_branch)} · commit <span class=\"path\">\{pipeline_html(run.commit_sha[:12].to_owned())}</span> · created \{pipeline_html(run.created_at)}</p>"
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
      b <+
        "<p class=\"muted\">Rerun snapshot executes this saved revision. <a href=\"\{@web_ui.repo_link(scope.repo)}/pipelines/new?branch=\{@web_context.url_escape_path(run.source_branch)}&amp;workflow=\{@web_context.url_escape_path(run.workflow_path)}\">Run latest branch revision</a></p><div class=\"pipeline-workspace\"><nav class=\"job-navigation\" aria-label=\"Pipeline jobs\"><h2>Jobs</h2>"
      for page in jobs {
        let state = pipeline_job_state(page.job.state)
        let conclusion = pipeline_conclusion(page.job.conclusion)
        let display = if conclusion.is_empty() { state } else { conclusion }
        b <+
          "<a href=\"#job-\{page.job.id.to_string()}\" data-job-select=\"\{page.job.id.to_string()}\"><span>\{page.job.job_key}</span><span class=\"mr-state\" data-nav-job-state data-state=\"\{display}\">\{pipeline_display_state(display)}</span></a>"
      }
      b <+ "</nav><ol class=\"mr-list pipeline-job-panels\">"
      for page in jobs {
        let state = pipeline_job_state(page.job.state)
        let conclusion = pipeline_conclusion(page.job.conclusion)
        let display = if conclusion.is_empty() { state } else { conclusion }
        b <+
          "<li id=\"job-\{page.job.id.to_string()}\" data-pipeline-job=\"\{page.job.id.to_string()}\" data-attempt-id=\"\{page.job.attempt_id.map(id => id.to_string()).unwrap_or("")}\"><div class=\"mr-list-title\"><strong>\{pipeline_html(page.job.job_key)}</strong><span class=\"mr-state\" data-job-state data-state=\"\{display}\">\{pipeline_display_state(display)}</span></div>"
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
            "<li data-step-id=\"\{step.step_id}\"><button class=\"step-select secondary-button\" type=\"button\" data-select-step=\"\{step.step_id}\">\{step.step_id}</button><span class=\"muted\" data-step-exit"
          if step.state == "running" ||
            step.state == "queued" ||
            step.state == "waiting" {
            b <+ " hidden"
          }
          b <+
            ">exit \{step.exit_code.to_string()}</span> <span class=\"mr-state\" data-step-state data-state=\"\{step.state}\">\{pipeline_display_state(step.state)}</span></li>"
        }
        b <+ "</ul>"
        let chunks = page.logs.map(logs => logs.chunks).unwrap_or([])
        b <+
          "<section class=\"pipeline-logs\" aria-label=\"Job logs\" data-log-cursor=\"\{page.logs.map(logs => logs.next_cursor).unwrap_or("0")}\" data-log-complete=\"\{page.logs.map(logs => logs.complete).unwrap_or(true).to_string()}\" data-log-more=\"\{page.logs.map(logs => logs.has_more).unwrap_or(false).to_string()}\""
        if chunks.is_empty() {
          b <+ " hidden"
        }
        b <+
          "><h3>Logs</h3><div class=\"log-toolbar\" hidden><label><span class=\"sr-only\">Search logs</span><input type=\"search\" data-log-search placeholder=\"Search loaded logs\"></label><button class=\"secondary-button\" type=\"button\" data-log-previous aria-label=\"Previous match\">Previous</button><button class=\"secondary-button\" type=\"button\" data-log-next aria-label=\"Next match\">Next</button><button class=\"secondary-button\" type=\"button\" data-log-error>Find error output</button><label class=\"checkbox-field\"><input type=\"checkbox\" data-log-wrap checked>Wrap</label><label class=\"checkbox-field\"><input type=\"checkbox\" data-log-follow>Follow</label><button class=\"secondary-button\" type=\"button\" data-log-end>End</button><button class=\"secondary-button\" type=\"button\" data-log-all>All steps</button><button class=\"secondary-button\" type=\"button\" data-log-copy>Copy</button><button class=\"secondary-button\" type=\"button\" data-log-download>Download</button></div><p class=\"log-feedback muted\" data-log-feedback role=\"status\" aria-live=\"polite\"></p><pre tabindex=\"0\" aria-label=\"Job log output\">"
        for log in chunks {
          b <+
            "<span data-log-chunk=\"\{log.id}\" data-log-step=\"\{log.step_id}\">\{log.text}</span>"
        }
        b <+ "</pre></section>"
        b <+ "</li>"
      }
      b <+ "</ol></div></section>"
    }),
    head_end=Html(b => {
      b <+ "\{@web_assets.repository_assets_head(assets)}"
      let script = @web_assets.vite_manifest_entry_path(
        assets, "src/pipeline-logs.ts",
      )
      b <+ "<link rel=\"modulepreload\" href=\"\{script}\">"
    }),
    current_user=Some(user),
    navigation=@web_ui.RepositoryNavigation(scope.repo, "pipelines", manager),
  )
}
