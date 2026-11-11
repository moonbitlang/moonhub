///|
pub struct WorkflowChoice {
  path : String
  name : String
  reason : String
  inputs : Array[@workflow.DispatchInput]
  jobs : Array[String]
  dispatch : Bool
}

///|
pub(all) struct DispatchChoices {
  branches : Array[String]
  branch : String
  commit : String
  workflows : Array[WorkflowChoice]
}

///|
pub async fn dispatch_choices(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  requested : String,
) -> DispatchChoices {
  let scope = require_run_author(pool, actor, repo)
  let git_dir = @repository.resolve_repository_dir(root, repo)
  let branches = @domain.split_lines(
    @gitops.merge_git(git_dir, [
      "for-each-ref", "--format=%(refname:strip=2)", "--count=1000", "refs/heads/",
    ]),
  )
  let default = @gitops.default_ref(git_dir)
  let branch = if !requested.is_empty() {
    requested
  } else if branches.contains(default) {
    default
  } else if branches.contains("main") {
    "main"
  } else if branches.contains("master") {
    "master"
  } else {
    branches.get(0).unwrap_or("")
  }
  if branch.is_empty() {
    return { branches, branch, commit: "", workflows: [], }
  }
  let commit = @gitops.branch_sha(git_dir, branch)
  let paths = @domain.split_lines(
    @gitops.merge_git(git_dir, [
      "ls-tree", "--name-only", commit, ".github/workflows/",
    ]),
  ).filter(path => path.has_suffix(".yml") || path.has_suffix(".yaml"))
  guard paths.length() <= 64 else {
    raise @domain.BadRequest(
      message="repository has more than 64 workflow files",
    )
  }
  let workflows : Array[WorkflowChoice] = []
  for path in paths {
    let (name, reason, inputs, jobs, dispatch) = try {
      validate_workflow_path(path)
      let source = read_workflow_source(git_dir, commit, path)
      let definition = @workflow.parse(source)
      let trigger = @workflow.triggers(source)
      (
        if definition.name.is_empty() {
          path
        } else {
          definition.name
        },
        "",
        trigger.inputs,
        definition.jobs.fold(init=Array(capacity=16), (ids, job) => {
          let id = if job.matrix_group.is_empty() {
            job.id
          } else {
            job.matrix_group
          }
          if !ids.contains(id) {
            ids.push(id)
          }
          ids
        }),
        trigger.dispatch,
      )
    } catch {
      @workflow.InvalidWorkflow(message) | @domain.BadRequest(message~) =>
        (path, message, [], [], false)
      SnapshotError(_) => (path, "Workflow could not be read", [], [], false)
      err => raise err
    }
    workflows.push({ path, name, reason, inputs, jobs, dispatch, })
  }
  ignore(require_run_author(pool, actor, scope.repo))
  { branches, branch, commit, workflows, }
}
