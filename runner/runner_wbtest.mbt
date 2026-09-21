///|
fn test_step(
  id : String,
  run : String,
  shell? : String = "bash",
  directory? : String = ".",
  env? : Map[String, String] = Map([]),
) -> @protocol.StepPlan {
  {
    id,
    name: id,
    run,
    shell,
    working_directory: directory,
    env,
    timeout_minutes: 0,
  }
}

///|
fn test_assignment(steps : Array[@protocol.StepPlan]) -> @protocol.Assignment {
  {
    version: 1,
    attempt_id: "1",
    run_id: "1",
    job_id: "1",
    repository: "alice/demo",
    commit_sha: "a".repeat(40),
    lease_until_ms: "60000",
    server_time_ms: "0",
    state: "leased",
    job: {
      id: "build",
      name: "Build",
      runs_on: ["self-hosted", "linux"],
      timeout_minutes: 1,
      steps,
    },
  }
}

///|
priv struct FakeServer {
  logs : Array[@protocol.LogRequest]
  events : Array[@protocol.StepRequest]
  mut execution_id : String
  mut sequence : Int64
  mut started : Int64
  mut heartbeats : Int
  cancel_after : Int
  available : Bool
  remaining_ms : Int64
  job_ms : Int64
}

///|
fn fake_server(
  cancel_after? : Int = 0,
  available? : Bool = true,
  remaining_ms? : Int64 = 60000L,
  job_ms? : Int64 = 60000L,
) -> FakeServer {
  {
    logs: [],
    events: [],
    execution_id: "",
    sequence: 0L,
    started: 0L,
    heartbeats: 0,
    cancel_after,
    available,
    remaining_ms,
    job_ms,
  }
}

///|
async fn FakeServer::post(
  self : FakeServer,
  operation : String,
  body : Json,
  until : Int64,
) -> (@protocol.LeaseState, Int64) {
  let now = monotonic_ms()
  let mut conclusion = ""
  if operation == "start" {
    let request : @protocol.StartRequest = @json.from_json(body)
    self.execution_id = request.execution_id
    self.started = now
  } else if operation == "heartbeat" {
    self.heartbeats += 1
    if !self.available {
      @async.sleep(Int64::max(1L, until - now + 100L).to_int())
      raise TransportFailure
    }
  } else if operation == "logs" {
    let request : @protocol.LogRequest = @json.from_json(body)
    self.logs.push(request)
    assert_eq(request.sequence, (self.sequence + 1L).to_string())
    self.sequence += 1L
  } else if operation == "steps" {
    self.events.push(@json.from_json(body))
  } else if operation == "complete" {
    let request : @protocol.CompleteRequest = @json.from_json(body)
    assert_eq(request.last_log_sequence, self.sequence.to_string())
    conclusion = request.conclusion
  }
  (
    {
      version: 1,
      execution_id: self.execution_id,
      attempt_id: "1",
      state: if operation == "complete" {
        "completed"
      } else {
        "running"
      },
      lease_until_ms: (self.started + self.remaining_ms).to_string(),
      server_time_ms: now.to_string(),
      deadline_ms: (self.started + self.job_ms).to_string(),
      cancel_requested: self.cancel_after > 0 &&
      self.heartbeats >= self.cancel_after,
      log_sequence: self.sequence.to_string(),
      conclusion,
    },
    now,
  )
}

///|
fn test_options(launcher : String, workspace : String) -> Options {
  {
    server: "http://127.0.0.1:1",
    workspace,
    launcher,
    allow_http: true,
    unsafe_local: true,
    heartbeat_ms: 50,
  }
}

///|
async test "malformed assignment strings are rejected before execution" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let assignment = test_assignment([test_step("check", "touch executed")])
    for
      invalid in [
        { ..assignment, attempt_id: "../1", },
        { ..assignment, attempt_id: "9223372036854775808", },
        { ..assignment, run_id: "0", },
        { ..assignment, job_id: "01", },
        { ..assignment, server_time_ms: "-1", },
        { ..assignment, lease_until_ms: "60001", },
      ] {
      let server = fake_server()
      try
        ignore(
          execute_assignment(invalid, test_options(launcher, workspace), (
            operation,
            body,
            until,
          ) => server.post(operation, body, until)),
        )
      catch {
        InvalidConfiguration(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid assignment numbers")
      }
      assert_eq(server.execution_id, "")
    }
    assert_true(!@fs.exists(workspace + "/executed"))
  })
}

///|
async test "malformed lease strings stop runner before executing steps" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let server = fake_server()
    let assignment = test_assignment([test_step("check", "touch executed")])
    for
      field in [
        "lease_until_ms", "server_time_ms", "deadline_ms", "log_sequence",
      ] {
      for value in ["-1", "01", "1e3", "9223372036854775808"] {
        let report = execute_assignment(
          assignment,
          test_options(launcher, workspace),
          (operation, body, until) => {
            let (state, sent) = server.post(operation, body, until)
            let state = match field {
              "lease_until_ms" => { ..state, lease_until_ms: value, }
              "server_time_ms" => { ..state, server_time_ms: value, }
              "deadline_ms" => { ..state, deadline_ms: value, }
              _ => { ..state, log_sequence: value, }
            }
            (state, sent)
          },
        )
        assert_eq(report.conclusion, "lost")
        assert_true(!report.reported)
        assert_true(!@fs.exists(workspace + "/executed"))
      }
    }
  })
}

///|
test "UTF-8 streaming retains split code points and bounds incomplete input" {
  let bytes = @utf8.encode("hello\u{4e2d}\u{1f680}")
  for cut = 1; cut < bytes.length(); cut = cut + 1 {
    let (first, tail) = decode_chunk(bytes[:cut].to_owned())
    let (second, pending) = decode_chunk(
      Bytes::from_array([..tail.to_array(), ..bytes[cut:].to_array()]),
    )
    assert_eq(
      first + second + @utf8.decode_lossy(pending),
      "hello\u{4e2d}\u{1f680}",
    )
  }
  assert_eq(decode_chunk(b"\xff").0, "\u{fffd}")
}

///|
async test "steps share workspace but not shell environment and upload both streams" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let server = fake_server()
    let assignment = test_assignment([
      test_step(
        "one",
        "export LEAK=bad\nprintf '%s' \"$VALUE\" > value\nprintf 'first\\n'\nprintf 'error\\n' >&2",
        env={ "VALUE": "saved" },
      ),
      test_step(
        "two", "test -z \"${LEAK:-}\"\ntest \"$(cat value)\" = saved\ntest \"$HOME\" = \"$GITHUB_WORKSPACE/.home\"\nprintf 'second\\n'",
      ),
    ])
    let report = execute_assignment(
      assignment,
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
    )
    assert_eq(report.conclusion, "success")
    assert_true(report.reported)
    assert_eq(report.steps.map(step => step.state), ["success", "success"])
    assert_eq(server.events.map(event => event.state), [
      "running", "success", "running", "success",
    ])
    assert_true(
      server.logs.any(log => {
        log.stream == "stderr" && log.text.contains("error")
      }),
    )
    assert_true(
      server.logs.any(log => log.step_id == "two" && log.text.contains("second")),
    )
    let installed_config = "/opt/moon/config.json"
    let job_config = workspace + "/.home/.moon/config.json"
    if @fs.exists(installed_config) {
      assert_eq(
        @fs.read_file(job_config).text(),
        @fs.read_file(installed_config).text(),
      )
    } else {
      assert_false(@fs.exists(job_config))
    }
  })
}

///|
async test "implicit bash and explicit bash retain their different pipefail behavior" {
  for (shell, expected) in [("", "success"), ("bash", "failure")] {
    @test_support.with_runner_workspace((_, launcher, workspace) => {
      let server = fake_server()
      let report = execute_assignment(
        test_assignment([test_step("pipe", "false | true", shell~)]),
        test_options(launcher, workspace),
        (operation, body, until) => server.post(operation, body, until),
      )
      assert_eq(report.conclusion, expected)
    })
  }
}

///|
async test "a failed step skips later steps" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let server = fake_server()
    let report = execute_assignment(
      test_assignment([
        test_step("bad", "exit 7"),
        test_step("skip", "touch should-not-exist"),
      ]),
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
    )
    assert_eq(report.conclusion, "failure")
    assert_eq(report.steps[0].exit_code, 7)
    assert_eq(report.steps[1].state, "skipped")
    assert_true(!@fs.exists(workspace + "/should-not-exist"))
  })
}

///|
async test "background pipe holders do not block later steps and are cleaned up at job end" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let server = fake_server()
    let report = execute_assignment(
      test_assignment([
        test_step("background", "(sleep 2; touch late) &"),
        test_step("next", "test ! -e late"),
      ]),
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
    )
    assert_eq(report.conclusion, "success")
    @async.sleep(2100)
    assert_true(!@fs.exists(workspace + "/late"))
  })
}

///|
async test "cancellation kills shell and background process group" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let server = fake_server(cancel_after=2)
    let report = execute_assignment(
      test_assignment([test_step("long", "(sleep 1; touch survivor) &\nwait")]),
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
    )
    assert_eq(report.conclusion, "cancelled")
    @async.sleep(1100)
    assert_true(!@fs.exists(workspace + "/survivor"))
  })
}

///|
async test "lost lease stops execution without waiting indefinitely for heartbeat" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let server = fake_server(available=false, remaining_ms=1400L)
    let began = monotonic_ms()
    let report = execute_assignment(
      test_assignment([test_step("long", "sleep 1; touch survivor")]),
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
    )
    assert_eq(report.conclusion, "lost")
    assert_true(!report.reported)
    assert_true(monotonic_ms() - began < 3000L)
    @async.sleep(1100)
    assert_true(!@fs.exists(workspace + "/survivor"))
  })
}

///|
async test "working directory symlinks cannot select a path outside workspace" {
  @test_support.with_runner_workspace((root, launcher, workspace) => {
    let server = fake_server()
    let report = execute_assignment(
      test_assignment([
        test_step("link", "ln -s '" + root + "' outside"),
        test_step("escape", "touch sentinel", directory="outside"),
      ]),
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
    )
    assert_eq(report.conclusion, "failure")
    assert_true(!@fs.exists(root + "/sentinel"))
  })
}

///|
async test "output limits stop noisy steps without unbounded buffering" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let server = fake_server()
    let report = execute_assignment(
      test_assignment([
        test_step(
          "noisy", "while :; do printf 'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n'; done",
        ),
      ]),
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
    )
    assert_eq(report.conclusion, "failure")
    assert_true(server.logs.length() <= 4096)
    assert_true(
      server.logs
      .map(log => @utf8.encode(log.text).length())
      .fold(init=0, (sum, n) => sum + n) <=
      1048576,
    )
  })
}

///|
async test "job deadline stops a step and skips later commands" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let server = fake_server(job_ms=1400L)
    let report = execute_assignment(
      test_assignment([
        test_step("timeout", "sleep 1; touch survivor"),
        test_step("skip", "touch skipped"),
      ]),
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
    )
    assert_eq(report.conclusion, "timed_out")
    assert_eq(report.steps[1].state, "skipped")
    @async.sleep(1100)
    assert_true(!@fs.exists(workspace + "/survivor"))
    assert_true(!@fs.exists(workspace + "/skipped"))
  })
}

///|
async test "reserved loader environment and reused workspaces fail before start" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    for
      name in [
        "BASH_ENV", "LD_PRELOAD", "DYLD_INSERT_LIBRARIES", "MOONHUB_TOKEN",
      ] {
      let server = fake_server()
      let plan = test_assignment([
        test_step("bad", "echo bad", env=Map([(name, "bad")])),
      ])
      try
        ignore(
          execute_assignment(plan, test_options(launcher, workspace), (
            operation,
            body,
            until,
          ) => server.post(operation, body, until)),
        )
      catch {
        InvalidConfiguration(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted loader environment")
      }
      assert_eq(server.execution_id, "")
    }
    @fs.write_file(workspace + "/existing", "keep")
    let server = fake_server()
    try
      ignore(
        execute_assignment(
          test_assignment([test_step("bad", "echo bad")]),
          test_options(launcher, workspace),
          (operation, body, until) => server.post(operation, body, until),
        ),
      )
    catch {
      InvalidConfiguration(_) => ()
      err => raise err
    } noraise {
      _ => fail("reused existing workspace")
    }
    assert_eq(@fs.read_file(workspace + "/existing").text(), "keep")
  })
}
