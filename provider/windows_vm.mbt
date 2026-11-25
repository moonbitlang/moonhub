///|
async fn run_windows_vm_worker(base : Options, token : String) -> Unit {
  validate_options(base)
  guard @platform.windows_build() == 26100 &&
    @platform.architecture() == "x64" &&
    @platform.path_key(base.workspace_root) ==
    "c:/programdata/moonhub/workspace" else {
    raise InvalidConfiguration(
      "Windows VM requires the prepared Server 2025 x64 guest and its default workspace root.",
    )
  }
  let isolated = Ref(false)
  run_backend_worker(base, token, {
    os: "windows",
    fresh_each_job: true,
    initialize: () => {
      guard @fs.kind("C:/moonhub/ci-host.ps1", follow_symlink=false) is Regular &&
        @fs.kind("C:/moonhub/bin/moonhub-runner-step.exe", follow_symlink=false)
        is Regular else {
        raise InvalidConfiguration(
          "The Windows VM runner bundle is incomplete.",
        )
      }
    },
    prepare: _ => (),
    prepare_claim: _ => {
      if !isolated.val {
        run_windows_vm_host(["-Isolate"], 180000)
        isolated.val = true
      }
    },
    health: () => (),
    execute: (options, assignment, credential) => {
      let root = options.workspace_root + "/" + assignment.attempt_id
      @platform.private_directory(root)
      @fs.write_file(
        root + "/assignment.json",
        ToJson::to_json(assignment).stringify(),
        create_mode=@fs.CreateNew,
        permission=0o600,
      )
      let dispatch : Json = {
        "server": options.runner_server,
        "allow_http": options.allow_http,
        "token": credential,
      }
      @fs.write_file(
        root + "/dispatch.json",
        dispatch.stringify(),
        create_mode=@fs.CreateNew,
        permission=0o600,
      )
      run_windows_vm_host(
        ["-StartJob", assignment.attempt_id],
        assignment.job.timeout_minutes * 60000 + 90000,
      )
    },
    cleanup: () => (),
  })
}

///|
async fn run_windows_vm_host(args : Array[String], timeout_ms : Int32) -> Unit {
  let command = [
    "-NoLogo", "-NoProfile", "-NonInteractive", "-File", "C:/moonhub/ci-host.ps1",
  ]
  command.append(args)
  @async.with_timeout(timeout_ms, () => {
    let code = @process.run(
      "C:/moonhub/pwsh/pwsh.exe",
      command,
      inherit_env=false,
      extra_env=@platform.environment(),
      no_console_window=true,
    )
    guard code == 0 else {
      raise InvalidConfiguration(
        "Windows VM guest preparation or task execution failed.",
      )
    }
  })
}
