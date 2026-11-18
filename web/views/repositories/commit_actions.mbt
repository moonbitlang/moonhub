///|
fn commit_workflow_status(
  run : @pipeline.CommitWorkflowRun,
) -> (String, String, String) {
  match run.conclusion {
    Some(@pipeline.Success) => ("success", "check", "Passed")
    Some(@pipeline.Failure) => ("failure", "x", "Failed")
    Some(@pipeline.TimedOut) => ("failure", "x", "Timed out")
    Some(@pipeline.Lost) => ("failure", "x", "Runner lost")
    Some(@pipeline.Cancelled) => ("neutral", "ellipsis", "Cancelled")
    Some(@pipeline.Skipped) => ("neutral", "ellipsis", "Skipped")
    None =>
      match run.state {
        @pipeline.Queued => ("pending", "circle-dot", "Queued")
        @pipeline.Running => ("pending", "circle-dot", "Running")
        @pipeline.Completed => ("neutral", "ellipsis", "Completed")
      }
  }
}

///|
fn render_commit_actions(
  repo : @domain.RepoId,
  runs : Array[@pipeline.CommitWorkflowRun],
) -> @moonback.Html {
  if runs.is_empty() {
    return Html(_ => ())
  }
  let base = "\{@web_ui.repo_link(repo)}/pipelines"
  let checks = runs.map(run => (run, commit_workflow_status(run)))
  let passed = checks.iter().filter(check => check.1.0 == "success").count()
  let (tone, icon, result) = if checks
    .iter()
    .any(check => check.1.0 == "failure") {
    ("failure", "x", "Failed")
  } else if checks.iter().any(check => check.1.0 == "pending") {
    ("pending", "circle-dot", "In progress")
  } else if runs.iter().any(run => run.conclusion is Some(@pipeline.Cancelled)) {
    ("neutral", "ellipsis", "Cancelled")
  } else if passed > 0 {
    ("success", "check", "Passed")
  } else {
    ("neutral", "ellipsis", "Completed")
  }
  let summary = "\{passed} of \{runs.length()} passed"
  let label = "Actions · \{result} · \{summary}"
  Html(b => {
    b <+
      "<details class=\"commit-actions\" data-dismissable><summary data-status=\"\{tone}\" aria-label=\"\{label}\" title=\"\{label}\"><span class=\"ui-icon\" data-icon=\"\{icon}\" aria-hidden=\"true\"></span></summary><div class=\"commit-actions-panel\"><div class=\"commit-actions-heading\"><strong>Actions</strong><span class=\"muted\">\{summary}</span></div><ul>"
    for (run, (tone, icon, status)) in checks {
      b <+
        "<li><a href=\"\{base}/\{run.number.to_string()}\"><span class=\"ui-icon\" data-icon=\"\{icon}\" data-status=\"\{tone}\" aria-hidden=\"true\"></span><span class=\"commit-action-name\">\{run.workflow_name}</span><span class=\"muted\">\{status}</span></a></li>"
    }
    b <+ "</ul></div></details>"
  })
}
