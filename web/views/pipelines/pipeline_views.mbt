///|
priv struct PipelineJobPage {
  job : @runtime.JobRun
  steps : Array[@protocol.StepState]
  report : @protocol.JobReport
  logs : @runtime.LogPage?
  reason : @runtime.QueueReason?
}

///|
fn queue_reason_text(reason : @runtime.QueueReason) -> String {
  match reason {
    @runtime.WaitingConcurrency =>
      "Waiting for the previous run in this concurrency group to finish."
    @runtime.WaitingMatrixCapacity =>
      "Waiting for an available matrix parallel slot."
    @runtime.ContainerIsolationUnavailable =>
      "Waiting for an authorized isolated Linux CI container provider."
    @runtime.WaitingApproval => "Waiting for deployment environment approval."
    @runtime.WaitingDependencies => "Waiting for dependency jobs to succeed."
    @runtime.RequesterUnavailable =>
      "The requester no longer has permission to run this job, or the repository is not ready."
    @runtime.NoAuthorizedProvider =>
      "No provider is authorized for this repository."
    @runtime.RunnerGroupUnavailable =>
      "The requested runner group is unknown, has no providers, or is not authorized for this repository."
    @runtime.NoMatchingLabels =>
      "No authorized provider matches all required job labels."
    @runtime.EnvironmentUnavailable =>
      "No authorized provider offers this job's saved execution image. Restore a matching environment before running this snapshot."
    @runtime.ProvidersPaused => "All matching providers are paused."
    @runtime.ProvidersBusy =>
      "All matching providers are busy with another job."
    @runtime.NoRecentProviderContact =>
      "No idle matching provider has contacted the server in the last minute."
    @runtime.AwaitingClaim =>
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
fn pipeline_run_state(state : @runtime.RunState) -> String {
  match state {
    @runtime.Queued => "queued"
    @runtime.Running => "running"
    @runtime.Completed => "completed"
  }
}

///|
fn pipeline_job_state(state : @runtime.JobState) -> String {
  match state {
    @runtime.Waiting => "waiting"
    @runtime.Queued => "queued"
    @runtime.Leased => "leased"
    @runtime.Running => "running"
    @runtime.Completed => "completed"
  }
}

///|
fn pipeline_conclusion(value : @runtime.Conclusion?) -> String {
  match value {
    None => ""
    Some(@runtime.Success) => "success"
    Some(@runtime.Failure) => "failure"
    Some(@runtime.Cancelled) => "cancelled"
    Some(@runtime.TimedOut) => "timed_out"
    Some(@runtime.Lost) => "lost"
    Some(@runtime.Skipped) => "skipped"
  }
}

///|
fn pipeline_result(
  state : @runtime.RunState,
  conclusion : @runtime.Conclusion?,
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
  runs : Array[@runtime.Run],
  manager : Bool,
  push_enabled : Bool,
  csrf : String,
  events : Array[@runtime.TriggerEvent],
  tab : String,
  variables~ : Array[@runtime.RepositoryVariable],
  page : Int64,
  status : String,
  branch : String,
  workflow : String,
  saved : Bool,
) -> @moonback.Html {
  let base = @web_ui.repo_link(scope.repo) + "/pipelines"
  @web_ui.layout(
    "Actions",
    assets,
    Html(b => {
      b <+ "<div class=\"page-heading page-heading--actions\"><h1>Actions</h1>"
      if manager && tab == "runs" {
        b <+ "<a class=\"button-link\" href=\"\{base}/new\">Run workflow</a>"
      } else if manager && tab == "variables" {
        b <+
          "<a class=\"button-link\" href=\"\{@web_ui.repo_link(scope.repo)}/settings/variables\">Manage variables</a>"
      }
      b <+ "</div>"
      if tab != "settings" {
        b <+ "<nav class=\"page-tabs\" aria-label=\"Actions views\">"
        for
          (key, label) in [
            ("runs", "Runs"),
            ("events", "Trigger events"),
            ("variables", "Variables"),
          ] {
          b <+ "<a href=\"\{base}?tab=\{key}\""
          if tab == key {
            b <+ " aria-current=\"page\""
          }
          b <+ ">\{label}</a>"
        }
        b <+ "</nav>"
      }
      if tab == "settings" {
        b <+
          "<section class=\"bounded-section\"><h2>Automatic workflows</h2><p class=\"muted\">Choose whether repository owners and administrators can trigger workflows by pushing code.</p>"
        if saved {
          b <+
            "<p class=\"settings-success\" role=\"status\">Actions settings saved.</p>"
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
          "<p class=\"page-subtitle\">Automatic workflow triggers and their outcomes.</p><ul class=\"event-list\">"
        for event in events {
          b <+
            "<li><div class=\"record-title\"><code>\{event.reference}</code><span class=\"muted\">\{event.state}</span></div><p><a class=\"path\" href=\"\{@web_ui.repo_link(scope.repo)}/commit/\{event.commit_sha}\">\{event.commit_sha[:12].to_owned()}</a>"
          if event.reference.strip_prefix("refs/heads/") is Some(branch) {
            b <+
              " · <a href=\"\{base}?tab=runs&amp;branch=\{@web_context.url_escape_path(branch.to_owned())}\">View branch runs</a>"
          }
          b <+ "</p>"
          b <+ "\{@web_ui.timestamp(event.created_at, relative=true)}"
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
          b <+ "<li class=\"empty-state\"><h2>No trigger events yet</h2></li>"
        }
        b <+ "</ul>"
      } else if tab == "variables" {
        b <+ "\{render_repository_variable_list(variables, None)}"
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
            "<li><div class=\"run-identity\"><span class=\"mr-state\" data-state=\"\{result}\">\{pipeline_display_state(result)}</span><div><a class=\"record-title\" href=\"\{base}/\{run.number.to_string()}\">#\{run.number.to_string()} · \{run.workflow_name}</a><p class=\"record-meta\"><span>\{run.source_branch}</span><a class=\"path\" href=\"\{@web_ui.repo_link(scope.repo)}/commit/\{run.commit_sha}\">\{run.commit_sha[:12].to_owned()}</a></p></div></div>\{@web_ui.timestamp(run.created_at, relative=true)}</li>"
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
    sidebar_content=if tab == "runs" {
      Some(
        Html(b => {
          let seen : Map[String, Bool] = Map([])
          b <+
            "<nav class=\"nav-group workflow-navigation\" aria-label=\"Workflows in this view\"><p class=\"nav-group-label\">Workflows in this view</p>"
          for run in runs {
            if !seen.contains(run.workflow_path) {
              seen[run.workflow_path] = true
              b <+
                "<a class=\"nav-item\" href=\"\{base}?tab=runs&amp;workflow=\{@web_context.url_escape_path(run.workflow_path)}&amp;status=\{@web_context.url_escape_path(status)}&amp;branch=\{@web_context.url_escape_path(branch)}\">\{run.workflow_name}</a>"
            }
          }
          if runs.is_empty() {
            b <+ "<p class=\"muted\">No workflows in this view.</p>"
          }
          b <+ "</nav>"
        }),
      )
    } else {
      None
    },
    navigation=@web_ui.RepositoryNavigation(
      scope.repo,
      match tab {
        "settings" => "action-settings"
        "events" => "pipeline-events"
        "variables" => "pipeline-variables"
        _ => "pipeline-runs"
      },
      manager,
    ),
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
        "<a class=\"back-link\" href=\"\{base}\">Back to Actions</a><div class=\"page-heading\"><div><h1>Run workflow</h1><p class=\"page-subtitle\">Select a branch, then a workflow available on that revision.</p></div></div>"
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
  run : @runtime.Run,
  jobs : Array[PipelineJobPage],
  manager : Bool,
  csrf : String,
  merge : @runtime.MergeCheckContext?,
  deployments~ : Array[@runtime.JobDeployment] = [],
  attempts~ : Array[@runtime.Run] = [],
  environments~ : Map[String, @environment.Definition] = Map([]),
) -> @moonback.Html {
  let base = @web_ui.repo_link(scope.repo) +
    "/pipelines/" +
    run.number.to_string()
  let result = pipeline_result(run.state, run.conclusion)
  @web_ui.layout(
    "Run #\{run.number.to_string()}",
    assets,
    Html(b => {
      b <+
        "<section data-pipeline-run data-deployment-signature=\"\{ToJson::to_json(deployments).stringify()}\" data-run-url=\"\{base}\" data-run-phase=\"\{pipeline_run_state(run.state)}\"><div class=\"mr-page-heading\"><div><p class=\"muted\"><a href=\"\{@web_ui.repo_link(scope.repo)}/pipelines\">Actions</a> / #\{run.number.to_string()}</p><h1>\{pipeline_html(run.workflow_name)}</h1></div><span class=\"mr-state\" data-run-state data-state=\"\{result}\">\{pipeline_display_state(result)}</span></div><p class=\"settings-notice\" data-update-error role=\"status\" hidden></p>"
      b <+
        "<p class=\"muted\">Branch \{pipeline_html(run.source_branch)} · commit <span class=\"path\">\{pipeline_html(run.commit_sha[:12].to_owned())}</span> · created \{@web_ui.timestamp(run.created_at)}</p>"
      b <+
        "<nav aria-label=\"Run attempts\"><span>Run \{run.public_id.to_string()} · attempt \{run.run_attempt.to_string()}</span>"
      for attempt in attempts {
        b <+
          " <a href=\"\{@web_ui.repo_link(scope.repo)}/pipelines/\{attempt.number.to_string()}\">Attempt \{attempt.run_attempt.to_string()}</a>"
      }
      b <+ "</nav>"
      if merge is Some(merge) {
        b <+
          "<p><a href=\"\{@web_ui.repo_link(scope.repo)}/merge-requests/\{merge.number.to_string()}?version=\{merge.version.to_string()}\">Pull request !\{merge.number.to_string()}, version \{merge.version.to_string()}</a></p><p class=\"muted mr-shas\"><span>Source <code>\{merge.source_sha[:12].to_owned()}</code></span><span>Target <code>\{merge.target_sha[:12].to_owned()}</code></span></p>"
      }
      if manager {
        b <+ "<div class=\"mr-actions\">"
        b <+ "<form data-run-cancel method=\"post\" action=\"\{base}/cancel\""
        if run.state is @runtime.Completed {
          b <+ " hidden"
        }
        b <+
          "><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button class=\"danger-button\" type=\"submit\">Cancel run</button></form><form data-run-rerun method=\"post\" action=\"\{base}/rerun\""
        if !(run.state is @runtime.Completed) {
          b <+ " hidden"
        }
        b <+
          "><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><button type=\"submit\">Rerun snapshot</button><button type=\"submit\" name=\"failed_only\" value=\"true\">Rerun failed jobs</button></form>"
        b <+ "</div>"
      }
      b <+
        "<p class=\"muted\">Rerun snapshot executes this saved revision. <a href=\"\{@web_ui.repo_link(scope.repo)}/pipelines/new?branch=\{@web_context.url_escape_path(run.source_branch)}&amp;workflow=\{@web_context.url_escape_path(run.workflow_path)}\">Run latest branch revision</a></p><div class=\"pipeline-workspace\"><nav class=\"job-navigation\" aria-label=\"Workflow jobs\"><h2>Jobs</h2>"
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
          "<li id=\"job-\{page.job.id.to_string()}\" data-pipeline-job=\"\{page.job.id.to_string()}\" data-report-revision=\"\{page.report.revision.to_string()}\" data-attempt-id=\"\{page.job.attempt_id.map(id => id.to_string()).unwrap_or("")}\"><div class=\"mr-list-title\"><strong>\{pipeline_html(page.job.job_key)}</strong><span class=\"mr-state\" data-job-state data-state=\"\{display}\">\{pipeline_display_state(display)}</span></div>"
        if deployments.iter().find_first(item => item.job_id == page.job.id)
          is Some(item) {
          b <+
            "<p>Deployment environment: <strong>\{item.name}</strong> · \{item.state}</p>"
          if !item.url.is_empty() {
            b <+
              "<p><a href=\"\{item.url}\" rel=\"noreferrer\">View deployment</a></p>"
          }
          for review in item.reviews {
            if review
              is {
                "decision": String(decision),
                "created_at": String(created),
                ..
              } {
              b <+ "<p class=\"muted\">\{decision} · \{created}</p>"
            }
          }
          if item.can_review {
            b <+
              "<form method=\"post\" action=\"\{base}/deployments/\{item.job_id.to_string()}\"><input type=\"hidden\" name=\"csrf_token\" value=\"\{csrf}\"><input type=\"hidden\" name=\"environment_id\" value=\"\{item.environment_id.to_string()}\"><input type=\"hidden\" name=\"policy_version\" value=\"\{item.policy_version.to_string()}\"><button type=\"submit\" name=\"decision\" value=\"approved\">Approve deployment</button><button type=\"submit\" name=\"decision\" value=\"rejected\">Reject deployment</button></form>"
          }
        }
        b <+ "<p class=\"settings-notice\" data-queue-reason"
        if page.reason is None {
          b <+ " hidden"
        }
        b <+ ">\{page.reason.map(queue_reason_text).unwrap_or("")}</p>"
        b <+ "<p class=\"settings-notice\" data-scheduling-error"
        if page.job.scheduling_error.is_empty() {
          b <+ " hidden"
        }
        b <+ ">\{pipeline_html(page.job.scheduling_error)}</p>"
        b <+ "<p class=\"settings-notice\" data-allowed-failure"
        if !(page.job.actual_conclusion is Some(Failure) &&
          page.job.conclusion is Some(Success)) {
          b <+ " hidden"
        }
        b <+
          ">This job failed; continue-on-error allows dependent jobs and the run to succeed.</p>"
        if page.job.reused_from is Some(number) {
          b <+
            "<p>Reused result from <a href=\"\{@web_ui.repo_link(scope.repo)}/pipelines/\{number.to_string()}\">run record #\{number.to_string()}</a>; logs and artifacts remain with that attempt.</p>"
        }
        let environment = environments.get(page.job.job_key)
        b <+ "<p class=\"muted\" data-job-environment"
        if environment is None {
          b <+ " hidden"
        }
        b <+ ">"
        if environment is Some(selected) {
          b <+
            "Environment: \{selected.name} · \{selected.selector} · \{selected.architecture}"
        }
        b <+
          "</p><details class=\"secondary-details environment-image\" data-job-environment-image"
        if environment is None {
          b <+ " hidden"
        }
        b <+
          "><summary>Execution image for \{page.job.job_key}</summary><code data-job-environment-reference>\{environment.map(value => value.image).unwrap_or("")}</code></details>"
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
        if page.report.truncated {
          b <+
            "<p class=\"settings-notice\">Some report content was omitted because the job report limit was reached.</p>"
        }
        if !page.report.entries.is_empty() {
          b <+
            "<section class=\"job-reports\" aria-label=\"Job reports\"><h3>Step summary</h3>"
          for entry in page.report.entries {
            if !entry.summary.is_empty() {
              b <+
                "<section data-summary-step=\"\{entry.step_id}\"><h4>\{entry.step_id}</h4><div class=\"markdown-body\">\{@web_ui.markdown(entry.summary,repo=Some(scope.repo))}</div></section>"
            }
          }
          b <+ "<h3>Annotations</h3><ul class=\"job-annotations\">"
          for entry in page.report.entries {
            for annotation in entry.annotations {
              b <+
                "<li data-annotation-severity=\"\{annotation.severity}\"><strong>\{annotation.severity}</strong> · <span>\{entry.step_id}</span>"
              if !annotation.title.is_empty() {
                b <+ "<h4>\{annotation.title}</h4>"
              }
              if !annotation.file.is_empty() {
                b <+ "<p><code>\{annotation.file}</code>"
              } else {
                b <+ "<p>"
              }
              if annotation.line > 0 {
                b <+ " · line \{annotation.line.to_string()}"
              }
              if annotation.end_line > annotation.line {
                b <+ "–\{annotation.end_line.to_string()}"
              }
              if annotation.column > 0 {
                b <+ " · column \{annotation.column.to_string()}"
              }
              if annotation.end_column > 0 &&
                annotation.end_column != annotation.column {
                b <+ "–\{annotation.end_column.to_string()}"
              }
              b <+ "</p><pre>\{annotation.message}</pre></li>"
            }
          }
          b <+ "</ul></section>"
        }
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
