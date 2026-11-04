///|
async fn Runtime::prepare_source_git(self : Runtime, scratch : String) -> Unit {
  let script = scratch + "/prepare-source.sh"
  @fs.write_file(
    script,
    (
      #|git -c core.hooksPath=/dev/null init --bare --quiet "$MOONHUB_SOURCE_GIT"
      #|git -c core.hooksPath=/dev/null --git-dir "$MOONHUB_SOURCE_GIT" bundle unbundle "$MOONHUB_SOURCE_BUNDLE" > /dev/null
      #|printf '%s\n' "$GITHUB_SHA" > "$MOONHUB_SOURCE_GIT/shallow"
      #|git -c core.hooksPath=/dev/null --git-dir "$MOONHUB_SOURCE_GIT" update-ref refs/heads/moonhub-source "$GITHUB_SHA"
      #|git -c core.hooksPath=/dev/null --git-dir "$MOONHUB_SOURCE_GIT" symbolic-ref HEAD refs/heads/moonhub-source
    ),
    create_mode=CreateNew,
    permission=0o600,
  )
  let base = self.assignment.job.steps[0]
  let code = self.execute_script(
    {
      ..base,
      uses: "",
      shell: "bash",
      working_directory: ".",
      env: {
        "MOONHUB_SOURCE_BUNDLE": scratch + "/source.bundle",
        "MOONHUB_SOURCE_GIT": scratch + "/source.git",
      },
    },
    script,
    30000,
  )
  guard code == 0 else {
    raise InvalidConfiguration("source bundle preparation failed")
  }
}

///|
async fn Runtime::execute_action_step(
  self : Runtime,
  step : @protocol.StepPlan,
  index : Int32,
  scratch : String,
  timeout : Int32,
  secrets : Map[String, String],
  failed : Bool,
) -> Int32 {
  let config : Json = {
    "workspace": self.options.workspace,
    "temp": self.action_temp,
    "repository": self.assignment.repository,
    "sha": self.assignment.commit_sha,
    "server": self.options.server,
    "run_id": self.assignment.run_id,
    "job_id": self.assignment.job.id,
    "source_git": if @fs.exists(scratch + "/source.git") {
      scratch + "/source.git"
    } else {
      ""
    },
    "failure": failed,
    "result_file": scratch + "/result-\{index}.json",
    "step": ToJson::to_json(step),
    "context": ToJson::to_json(self.assignment.job.context),
  }
  let filename = scratch + "/action-\{index}.json"
  @fs.write_file(
    filename,
    config.stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  self.execute_action_runtime(step, filename, timeout, secrets)
}

///|
async fn Runtime::execute_action_runtime(
  self : Runtime,
  step : @protocol.StepPlan,
  filename : String,
  timeout : Int32,
  secrets : Map[String, String],
) -> Int32 {
  let script = filename + ".sh"
  @fs.write_file(
    script,
    (
      #|exec "$MOONHUB_ACTION_NODE" "$MOONHUB_ACTION_RUNTIME" "$MOONHUB_ACTION_PLAN" "$MOONHUB_ACTION_STATE"
    ),
    create_mode=CreateNew,
    permission=0o600,
  )
  let env = step.env.copy()
  env["MOONHUB_ACTION_NODE"] = self.action_node
  env["MOONHUB_ACTION_RUNTIME"] = self.action_runtime
  env["MOONHUB_ACTION_PLAN"] = filename
  env["MOONHUB_ACTION_STATE"] = self.action_temp + "/state.json"
  env["MOONHUB_ACTION_STATE_KEY"] = self.action_state_key
  self.execute_script(
    { ..step, uses: "", shell: "bash", working_directory: ".", env, },
    script,
    timeout,
    secrets~,
  )
}

///|
async fn Runtime::execute_action_posts(
  self : Runtime,
  scratch : String,
  failed : Bool,
) -> Int32 {
  self.check_live()
  let timeout = Int64::min(self.deadline - monotonic_ms(), 2147483647L).to_int()
  let config : Json = {
    "phase": "post",
    "failure": failed,
    "run_id": self.assignment.run_id,
    "job_id": self.assignment.job.id,
    "context": ToJson::to_json(self.assignment.job.context),
    "workspace": self.options.workspace,
    "temp": self.action_temp,
    "repository": self.assignment.repository,
    "sha": self.assignment.commit_sha,
    "server": self.options.server,
    "source_git": if @fs.exists(scratch + "/source.git") {
      scratch + "/source.git"
    } else {
      ""
    },
  }
  let filename = scratch + "/post.json"
  @fs.write_file(
    filename,
    config.stringify(),
    create_mode=CreateNew,
    permission=0o600,
  )
  let step = {
    ..self.assignment.job.steps[self.assignment.job.steps.length() - 1],
    env: Map([]),
  }
  self.execute_action_runtime(step, filename, timeout, Map([]))
}
