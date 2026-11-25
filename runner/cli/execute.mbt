///|
pub async fn execute(args : ArrayView[String]) -> Int32 {
  if args.length() == 1 && args[0] == "--probe-environment" {
    println(ToJson::to_json(@runner.environment_probe()).stringify())
    return 0
  }
  let command = @argparse.Command(
    "runner",
    options=[
      @argparse.OptionArg("server", long="server", required=true),
      @argparse.OptionArg("assignment", long="assignment", required=true),
      @argparse.OptionArg("workspace", long="workspace", default_values=[
        if @platform.windows() {
          "C:/workspace"
        } else {
          "/workspace"
        },
      ]),
      @argparse.OptionArg("launcher", long="launcher", default_values=[
        if @platform.windows() {
          "C:/moonhub/bin/moonhub-runner-step.exe"
        } else {
          "/usr/local/bin/moonhub-runner-step"
        },
      ]),
    ],
    flags=[
      @argparse.FlagArg(
        "probe-environment",
        long="probe-environment",
        about="Inspect a task image without an assignment or credentials.",
      ),
      @argparse.FlagArg(
        "allow-http",
        long="allow-http",
        about="Allow plain HTTP on a trusted development network.",
      ),
      @argparse.FlagArg(
        "unsafe-local",
        long="unsafe-local",
        about="Run trusted tests outside a container; NOT a sandbox.",
      ),
      @argparse.FlagArg(
        "linux-ci",
        long="linux-ci",
        about="Execute in a prepared privileged single-use Linux CI container.",
      ),
      @argparse.FlagArg(
        "windows-vm",
        long="windows-vm",
        about="Execute inside a prepared disposable Windows Server 2025 guest.",
      ),
    ],
    about="Execute one leased assignment. Read its 64-character attempt credential from stdin.",
  )
  let options = command.parse(argv=args)
  let path = cli_value(options, "assignment")
  guard @fs.kind(path, follow_symlink=false) is Regular &&
    @fs.file_size(path) <= 2097152L else {
    raise @runner.InvalidConfiguration("invalid assignment file")
  }
  let assignment : @runner_protocol.Assignment = @json.from_json(
    @json.parse(@fs.read_file(path).text()),
  )
  let bytes : Array[Byte] = []
  @async.with_timeout(5000, () => {
    while bytes.length() <= 64 {
      let chunk = @stdio.stdin.read_some(max_len=1)
      guard chunk is Some(chunk) else { break }
      if chunk[0] == b'\r' {
        continue
      }
      if chunk[0] == b'\n' {
        break
      }
      bytes.push(chunk[0])
    }
  })
  let token = @utf8.decode(Bytes::from_array(bytes))
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM, SIGHUP, SIGBREAK])
  let report = @runner.run(assignment, token, {
    server: cli_value(options, "server"),
    workspace: cli_value(options, "workspace"),
    launcher: cli_value(options, "launcher"),
    allow_http: options.flags.get("allow-http").unwrap_or(false),
    unsafe_local: options.flags.get("unsafe-local").unwrap_or(false),
    linux_ci: options.flags.get("linux-ci").unwrap_or(false),
    windows_vm: options.flags.get("windows-vm").unwrap_or(false),
    heartbeat_ms: 5000,
  })
  println(ToJson::to_json(report).stringify())
  if !report.reported {
    2
  } else if report.conclusion == "success" {
    0
  } else {
    1
  }
}

///|
fn cli_value(options : @argparse.Matches, name : String) -> String {
  options.values.get(name).unwrap()[0]
}
