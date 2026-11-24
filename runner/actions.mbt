///|
async fn Runtime::prepare_source_git(self : Runtime, scratch : String) -> Unit {
  let release_ref = if self.assignment.job.context.get("event_name") ==
    Some("release") {
    let reference = self.assignment.job.context.get("ref").unwrap_or("")
    guard reference.has_prefix("refs/tags/") else {
      raise InvalidConfiguration("release source requires a tag ref")
    }
    reference
  } else {
    ""
  }
  let script = scratch + "/prepare-source.sh"
  @fs.write_file(
    script,
    if @platform.windows() {
      (
        #|& git -c core.hooksPath=NUL init --bare --quiet $env:MOONHUB_SOURCE_GIT
        #|if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        #|& git -c core.hooksPath=NUL --git-dir $env:MOONHUB_SOURCE_GIT bundle unbundle $env:MOONHUB_SOURCE_BUNDLE | Out-Null
        #|if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        #|[IO.File]::WriteAllText(($env:MOONHUB_SOURCE_GIT + '/shallow'), ($env:GITHUB_SHA + "`n"), [Text.UTF8Encoding]::new($false))
        #|& git -c core.hooksPath=NUL --git-dir $env:MOONHUB_SOURCE_GIT update-ref refs/heads/moonhub-source $env:GITHUB_SHA
        #|if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        #|if ($env:MOONHUB_RELEASE_REF) {
        #|  & git -c core.hooksPath=NUL --git-dir $env:MOONHUB_SOURCE_GIT update-ref $env:MOONHUB_RELEASE_REF $env:GITHUB_SHA
        #|  if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
        #|}
        #|& git -c core.hooksPath=NUL --git-dir $env:MOONHUB_SOURCE_GIT symbolic-ref HEAD refs/heads/moonhub-source
      )
    } else {
      (
        #|git -c core.hooksPath=/dev/null init --bare --quiet "$MOONHUB_SOURCE_GIT"
        #|git -c core.hooksPath=/dev/null --git-dir "$MOONHUB_SOURCE_GIT" bundle unbundle "$MOONHUB_SOURCE_BUNDLE" > /dev/null
        #|printf '%s\n' "$GITHUB_SHA" > "$MOONHUB_SOURCE_GIT/shallow"
        #|git -c core.hooksPath=/dev/null --git-dir "$MOONHUB_SOURCE_GIT" update-ref refs/heads/moonhub-source "$GITHUB_SHA"
        #|if [ -n "$MOONHUB_RELEASE_REF" ]; then
        #|  git -c core.hooksPath=/dev/null --git-dir "$MOONHUB_SOURCE_GIT" update-ref "$MOONHUB_RELEASE_REF" "$GITHUB_SHA" || exit $?
        #|fi
        #|git -c core.hooksPath=/dev/null --git-dir "$MOONHUB_SOURCE_GIT" symbolic-ref HEAD refs/heads/moonhub-source
      )
    },
    create_mode=CreateNew,
    permission=0o600,
  )
  let base = self.assignment.job.steps[0]
  let code = self.execute_script(
    {
      ..base,
      uses: "",
      shell: if @platform.windows() {
        "pwsh"
      } else {
        "bash"
      },
      working_directory: ".",
      env: {
        "MOONHUB_SOURCE_BUNDLE": scratch + "/source.bundle",
        "MOONHUB_SOURCE_GIT": scratch + "/source.git",
        "MOONHUB_RELEASE_REF": release_ref,
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
    "node20": self.action_node20,
    "reports_enabled": self.assignment.version >=
    @protocol.report_assignment_version,
    "api_permissions": self.assignment.job.api_permissions,
    "container_isolation": self.options.linux_ci &&
    self.assignment.version >= @protocol.container_assignment_version &&
    self.assignment.job.context.contains("container_plan"),
    "container_id": self.execution_id,
    "container_plan": self.assignment.job.context
    .get("container_plan")
    .map(value => @json.parse(value))
    .unwrap_or(Json::null()),
    "job_home": self.job_home,
    "workspace": self.options.workspace,
    "temp": self.action_temp,
    "repository": self.assignment.repository,
    "contents_read": self.assignment.job.contents_read,
    "matrix": ToJson::to_json(self.assignment.job.matrix),
    "strategy": ToJson::to_json(self.assignment.job.strategy),
    "needs": ToJson::to_json(self.assignment.job.needs),
    "job_outputs": ToJson::to_json(self.assignment.job.outputs),
    "variables_context": [
      @protocol.variable_assignment_version, @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
      @protocol.release_assignment_version, @protocol.profile_assignment_version,
      @protocol.compatibility_assignment_version, @protocol.run_attempt_assignment_version,
      @protocol.container_assignment_version, @protocol.source_assignment_version,
      @protocol.job_api_assignment_version, @protocol.report_assignment_version,
    ].contains(self.assignment.version) &&
    (
      self.assignment.version < @protocol.run_attempt_assignment_version ||
      self.assignment.job.context.get("variables_context") == Some("true")
    ),
    "variables": ToJson::to_json(self.assignment.job.variables),
    "dispatch_context": [
      @protocol.dispatch_assignment_version, @protocol.variable_assignment_version,
      @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
      @protocol.release_assignment_version, @protocol.profile_assignment_version,
      @protocol.compatibility_assignment_version, @protocol.run_attempt_assignment_version,
      @protocol.container_assignment_version, @protocol.source_assignment_version,
      @protocol.job_api_assignment_version, @protocol.report_assignment_version,
    ].contains(self.assignment.version) &&
    (
      self.assignment.version < @protocol.run_attempt_assignment_version ||
      self.assignment.job.context.get("dispatch_context") == Some("true")
    ),
    "dispatch_inputs": ToJson::to_json(self.assignment.job.dispatch_inputs),
    "event": ToJson::to_json(self.assignment.job.event),
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
  let code = self.execute_action_runtime(step, filename, timeout, secrets)
  self.publish_action_report(scratch + "/result-\{index}.json")
  code
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
    if @platform.windows() {
      (
        #|& $env:MOONHUB_ACTION_NODE $env:MOONHUB_ACTION_RUNTIME $env:MOONHUB_ACTION_PLAN $env:MOONHUB_ACTION_STATE
      )
    } else {
      (
        #|exec "$MOONHUB_ACTION_NODE" "$MOONHUB_ACTION_RUNTIME" "$MOONHUB_ACTION_PLAN" "$MOONHUB_ACTION_STATE"
      )
    },
    create_mode=CreateNew,
    permission=0o600,
  )
  let env = step.env.copy()
  if self.artifacts is Some(fetch) && step.remote {
    let grant = @async.with_timeout(Int32::min(timeout, 10000), () => {
      fetch({
        version: 1,
        execution_id: self.execution_id,
        origin: self.options.server,
      })
    })
    self.check_live()
    guard grant.results_url == self.options.server &&
      grant.token.length() <= 4096 else {
      raise InvalidResponse
    }
    env["MOONHUB_ACTION_ARTIFACT_TOKEN"] = grant.token
    env["MOONHUB_ACTION_ARTIFACT_URL"] = grant.results_url
  }
  if self.assignment.job.id_token_write {
    guard self.oidc is Some(fetch) else {
      raise InvalidConfiguration("OIDC service unavailable")
    }
    let grant = @async.with_timeout(Int32::min(timeout, 10000), () => {
      fetch({ version: 1, execution_id: self.execution_id, })
    })
    self.check_live()
    guard grant.token.length() == 64 &&
      grant.token
      .iter()
      .all(ch => ch.is_ascii_digit() || (ch >= 'a' && ch <= 'f')) &&
      grant.request_url.length() <= 512 &&
      (
        grant.request_url.has_prefix("https://") ||
        (self.options.allow_http && grant.request_url.has_prefix("http://"))
      ) else {
      raise InvalidResponse
    }
    env["MOONHUB_ACTION_OIDC_TOKEN"] = grant.token
    env["MOONHUB_ACTION_OIDC_URL"] = grant.request_url
  }
  if self.assignment.version >= @protocol.source_assignment_version &&
    (
      self.assignment.version < @protocol.report_assignment_version ||
      self.assignment.job.context.get("dependency_access") == Some("true")
    ) {
    guard self.dependencies is Some(fetch) else {
      raise InvalidConfiguration("dependency service unavailable")
    }
    let grant = @async.with_timeout(Int32::min(timeout, 10000), () => {
      fetch({ version: 1, execution_id: self.execution_id, })
    })
    self.check_live()
    guard grant.token.length() == 64 &&
      grant.token.iter().all(c => c.is_ascii_digit() || ('a' <= c && c <= 'f')) else {
      raise InvalidResponse
    }
    env["MOONHUB_ACTION_DEPENDENCY_TOKEN"] = grant.token
    env["MOONHUB_ACTION_DEPENDENCY_URL"] = self.options.server +
      "/-/runner-api/v1/dependencies"
  }
  if self.assignment.job.api_permissions != 0 {
    guard self.api is Some(fetch) else {
      raise InvalidConfiguration("job API service unavailable")
    }
    let grant = @async.with_timeout(Int32::min(timeout, 10000), () => {
      fetch({ version: 1, execution_id: self.execution_id, })
    })
    self.check_live()
    guard grant.token.length() == 64 &&
      grant.token
      .iter()
      .all(ch => ch.is_ascii_digit() || ('a' <= ch && ch <= 'f')) else {
      raise InvalidResponse
    }
    env["MOONHUB_ACTION_API_TOKEN"] = grant.token
  }
  env["MOONHUB_ACTION_NODE"] = self.action_node
  env["MOONHUB_ACTION_RUNTIME"] = self.action_runtime
  env["MOONHUB_ACTION_PLAN"] = filename
  env["MOONHUB_ACTION_STATE"] = self.action_temp + "/state.json"
  env["MOONHUB_ACTION_STATE_KEY"] = self.action_state_key
  self.execute_script(
    {
      ..step,
      uses: "",
      shell: if @platform.windows() {
        "pwsh"
      } else {
        "bash"
      },
      working_directory: ".",
      env,
    },
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
    "result_file": scratch + "/job-outputs.json",
    "failure": failed,
    "run_id": self.assignment.run_id,
    "job_id": self.assignment.job.id,
    "context": ToJson::to_json(self.assignment.job.context),
    "node20": self.action_node20,
    "reports_enabled": self.assignment.version >=
    @protocol.report_assignment_version,
    "api_permissions": self.assignment.job.api_permissions,
    "container_isolation": self.options.linux_ci &&
    self.assignment.version >= @protocol.container_assignment_version &&
    self.assignment.job.context.contains("container_plan"),
    "container_id": self.execution_id,
    "container_plan": self.assignment.job.context
    .get("container_plan")
    .map(value => @json.parse(value))
    .unwrap_or(Json::null()),
    "job_home": self.job_home,
    "workspace": self.options.workspace,
    "temp": self.action_temp,
    "repository": self.assignment.repository,
    "contents_read": self.assignment.job.contents_read,
    "matrix": ToJson::to_json(self.assignment.job.matrix),
    "strategy": ToJson::to_json(self.assignment.job.strategy),
    "needs": ToJson::to_json(self.assignment.job.needs),
    "job_outputs": ToJson::to_json(self.assignment.job.outputs),
    "variables_context": [
      @protocol.variable_assignment_version, @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
      @protocol.release_assignment_version, @protocol.profile_assignment_version,
      @protocol.compatibility_assignment_version, @protocol.run_attempt_assignment_version,
      @protocol.container_assignment_version, @protocol.source_assignment_version,
      @protocol.job_api_assignment_version, @protocol.report_assignment_version,
    ].contains(self.assignment.version) &&
    (
      self.assignment.version < @protocol.run_attempt_assignment_version ||
      self.assignment.job.context.get("variables_context") == Some("true")
    ),
    "variables": ToJson::to_json(self.assignment.job.variables),
    "dispatch_context": [
      @protocol.dispatch_assignment_version, @protocol.variable_assignment_version,
      @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
      @protocol.release_assignment_version, @protocol.profile_assignment_version,
      @protocol.compatibility_assignment_version, @protocol.run_attempt_assignment_version,
      @protocol.container_assignment_version, @protocol.source_assignment_version,
      @protocol.job_api_assignment_version, @protocol.report_assignment_version,
    ].contains(self.assignment.version) &&
    (
      self.assignment.version < @protocol.run_attempt_assignment_version ||
      self.assignment.job.context.get("dispatch_context") == Some("true")
    ),
    "dispatch_inputs": ToJson::to_json(self.assignment.job.dispatch_inputs),
    "event": ToJson::to_json(self.assignment.job.event),
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
    remote: self.assignment.job.steps.any(step => step.remote),
  }
  let code = self.execute_action_runtime(step, filename, timeout, Map([]))
  self.publish_action_report(scratch + "/job-outputs.json")
  if [
      @protocol.dataflow_assignment_version, @protocol.dispatch_assignment_version,
      @protocol.variable_assignment_version, @protocol.oidc_assignment_version, @protocol.environment_assignment_version,
      @protocol.release_assignment_version, @protocol.profile_assignment_version,
      @protocol.compatibility_assignment_version, @protocol.run_attempt_assignment_version,
      @protocol.container_assignment_version, @protocol.source_assignment_version,
      @protocol.job_api_assignment_version, @protocol.report_assignment_version,
    ].contains(self.assignment.version) {
    let bytes = @fs.read_file(scratch + "/job-outputs.json")
    guard bytes.binary().length() <=
      (if self.assignment.version >= @protocol.report_assignment_version {
        4259840
      } else {
        65536
      }) else {
      raise InvalidResponse
    }
    let result = @json.parse(bytes.text())
    guard result is { "outputs": value, .. } else { raise InvalidResponse }
    self.job_outputs = @json.from_json(value)
  }
  code
}

///|
// This runs outside the cancelled step group with no execution credentials.
// If cleanup cannot be verified, report lost and retain the provider's fence.
async fn Runtime::cleanup_containers(self : Runtime) -> Unit {
  guard self.options.linux_ci &&
    self.assignment.version >= @protocol.container_assignment_version &&
    self.assignment.job.context.contains("container_plan") else {
    return
  }
  let base = self.action_runtime.strip_suffix("runtime.mjs")
  guard base is Some(base) else { raise Stopped("lost") }
  let code = @async.with_timeout(15000, () => {
    @process.run(
      self.action_node,
      [base.to_owned() + "containers.mjs", "cleanup", self.execution_id],
      inherit_env=false,
      extra_env=@platform.environment(),
    )
  })
  guard code == 0 else { raise Stopped("lost") }
}

///|
async fn Runtime::publish_action_report(
  self : Runtime,
  filename : String,
) -> Unit {
  if self.assignment.version < @protocol.report_assignment_version ||
    !@fs.exists(filename) {
    return
  }
  let file = @fs.read_file(filename)
  guard file.binary().length() <= 4259840 else { raise InvalidResponse }
  if @json.parse(file.text()) is { "report": report, .. } {
    ignore(
      self.request("reports", {
        "version": 1,
        "execution_id": self.execution_id,
        "report": report,
      }),
    )
  }
}
