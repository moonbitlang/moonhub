///|
pub async fn execute(args : ArrayView[String]) -> Int32 {
  let command = @argparse.Command(
    "runner",
    options=[
      @argparse.OptionArg("server", long="server", required=true),
      @argparse.OptionArg("assignment", long="assignment", required=true),
      @argparse.OptionArg("workspace", long="workspace", default_values=[
        "/workspace",
      ]),
      @argparse.OptionArg("launcher", long="launcher", default_values=[
        "/usr/local/bin/moonhub-runner-step",
      ]),
    ],
    flags=[
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
      if chunk[0] == b'\n' {
        break
      }
      bytes.push(chunk[0])
    }
  })
  let token = @utf8.decode(Bytes::from_array(bytes))
  @signal.set_global_cancellation_signals([SIGINT, SIGTERM])
  let report = @runner.run(assignment, token, {
    server: cli_value(options, "server"),
    workspace: cli_value(options, "workspace"),
    launcher: cli_value(options, "launcher"),
    allow_http: options.flags.get("allow-http").unwrap_or(false),
    unsafe_local: options.flags.get("unsafe-local").unwrap_or(false),
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
