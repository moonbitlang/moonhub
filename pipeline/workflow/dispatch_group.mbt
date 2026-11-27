///|
pub fn restrict_runner_group(
  workflow : Workflow,
  group : String,
) -> Workflow raise InvalidWorkflow {
  let jobs = workflow.jobs.map(job => {
    guard job.dynamic_matrix is None && job.reusable_call is None else {
      raise InvalidWorkflow(
        "runner_group does not support dynamic matrices or reusable workflows (job " +
        job.id +
        ")",
      )
    }
    if !job.runner_group.is_empty() {
      guard job.runner_group == group else {
        raise InvalidWorkflow(
          "job " + job.id + " already selects runner group " + job.runner_group,
        )
      }
      return job
    }
    // Ungrouped jobs without an OS label already route to Linux.
    let runs_on = if job.runs_on.any(label => {
        ["linux", "windows", "macos"].contains(label)
      }) {
      job.runs_on
    } else {
      job.runs_on + ["linux"]
    }
    { ..job, runs_on, runner_group: group, }
  })
  { ..workflow, jobs, }
}
