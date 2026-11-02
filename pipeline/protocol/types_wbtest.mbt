///|
test "wire state uses explicit string fields and scalar conclusions" {
  let state : LeaseState = {
    version: 1,
    execution_id: "",
    attempt_id: "42",
    state: "running",
    lease_until_ms: "60000",
    server_time_ms: "0",
    deadline_ms: "60000",
    cancel_requested: false,
    log_sequence: "1",
    conclusion: "",
  }
  let json = ToJson::to_json(state)
  assert_true(
    json
    is {
      "attempt_id": String("42"),
      "deadline_ms": String("60000"),
      "log_sequence": String("1"),
      "conclusion": String(""),
      ..
    },
  )
  let restored : LeaseState = @json.from_json(json)
  assert_eq(ToJson::to_json(restored), json)
  for
    field in [
      "attempt_id", "lease_until_ms", "server_time_ms", "deadline_ms", "log_sequence",
    ] {
    guard ToJson::to_json(state) is Object(fields) else {
      fail("expected object")
    }
    fields[field] = ToJson::to_json(1)
    try {
      let _ : LeaseState = @json.from_json(ToJson::to_json(fields))
    } catch {
      _ => ()
    } noraise {
      _ => fail("accepted JSON number for \{field}")
    }
  }
}

///|
test "wire string identifiers preserve values beyond JavaScript integer precision" {
  let state : LeaseState = {
    version: 1,
    execution_id: "",
    attempt_id: "9007199254740993",
    state: "leased",
    lease_until_ms: "60000",
    server_time_ms: "0",
    deadline_ms: "0",
    cancel_requested: false,
    log_sequence: "0",
    conclusion: "",
  }
  let json = ToJson::to_json(state)
  assert_true(
    json
    is {
      "attempt_id": String("9007199254740993"),
      "deadline_ms": String("0"),
      ..
    },
  )
  let restored : LeaseState = @json.from_json(json)
  assert_eq(restored.attempt_id, state.attempt_id)
}

///|
test "decimal wire values are canonical nonnegative and bounded" {
  for value in [0L, 1L, 9007199254740993L, 9223372036854775807L] {
    assert_eq(parse_decimal(value.to_string()), Some(value))
  }
  for
    value in [
      "", "-1", "-0", "+1", " 1", "1 ", "1\n", "01", "00", "1.0", "1e3", "0x10",
      "1_000", "../1", "9223372036854775808", "18446744073709551616",
    ] {
    assert_eq(parse_decimal(value), None)
  }
}

///|
test "assignment validates string identifiers and bounded timestamps" {
  let assignment : Assignment = {
    version: 1,
    attempt_id: "9007199254740993",
    run_id: "2",
    job_id: "3",
    repository: "alice/demo",
    commit_sha: "a".repeat(40),
    lease_until_ms: "60000",
    server_time_ms: "0",
    state: "leased",
    job: {
      id: "build",
      name: "Build",
      runs_on: ["self-hosted"],
      timeout_minutes: 1,
      steps: [],
    },
  }
  assert_true(assignment.has_valid_numbers())
  let restored : Assignment = @json.from_json(ToJson::to_json(assignment))
  assert_eq(restored.attempt_id, "9007199254740993")
  for id in ["0", "-1", "01", "../1", "9223372036854775808"] {
    assert_true(!{ ..assignment, attempt_id: id, }.has_valid_numbers())
    assert_true(!{ ..assignment, run_id: id, }.has_valid_numbers())
    assert_true(!{ ..assignment, job_id: id, }.has_valid_numbers())
  }
  for value in ["", "-1", "1e3", "9223372036854775808"] {
    assert_true(!{ ..assignment, lease_until_ms: value, }.has_valid_numbers())
    assert_true(!{ ..assignment, server_time_ms: value, }.has_valid_numbers())
  }
  assert_true(!{ ..assignment, lease_until_ms: "60001", }.has_valid_numbers())
  assert_true(!{ ..assignment, server_time_ms: "60001", }.has_valid_numbers())
  for
    field in [
      "attempt_id", "run_id", "job_id", "lease_until_ms", "server_time_ms",
    ] {
    guard ToJson::to_json(assignment) is Object(fields) else {
      fail("expected object")
    }
    fields[field] = ToJson::to_json(1)
    try {
      let _ : Assignment = @json.from_json(ToJson::to_json(fields))
    } catch {
      _ => ()
    } noraise {
      _ => fail("accepted JSON number for \{field}")
    }
  }
}

///|
test "log and completion requests use explicit string sequence fields" {
  let log : LogRequest = {
    version: 1,
    sequence: "1",
    step_id: "check",
    stream: "stdout",
    text: "hello",
  }
  let complete : CompleteRequest = {
    version: 1,
    conclusion: "success",
    last_log_sequence: "1",
  }
  assert_true(ToJson::to_json(log) is { "sequence": String("1"), .. })
  assert_true(
    ToJson::to_json(complete) is { "last_log_sequence": String("1"), .. },
  )
  let restored_log : LogRequest = @json.from_json(ToJson::to_json(log))
  let restored_complete : CompleteRequest = @json.from_json(
    ToJson::to_json(complete),
  )
  assert_eq(restored_log.sequence, "1")
  assert_eq(restored_complete.last_log_sequence, "1")
}

///|
test "wire job plan has no language-specific optional field representation" {
  let plan : JobPlan = {
    id: "build",
    name: "Build",
    runs_on: ["self-hosted", "linux"],
    timeout_minutes: 10,
    steps: [
      {
        id: "run",
        name: "Run",
        run: "echo test",
        uses: "",
        moonbit_version: "",
        shell: "",
        working_directory: ".",
        env: Map([]),
        timeout_minutes: 0,
      },
    ],
  }
  let json = ToJson::to_json(plan)
  assert_true(
    json
    is {
      "steps": Array(
        [{ "shell": String(""), "timeout_minutes": Number(0.0, ..), .. }]
      ),
      ..
    },
  )
  let restored : JobPlan = @json.from_json(json)
  assert_eq(ToJson::to_json(restored), json)
}

///|
test "legacy wire steps without uses still decode and action names remain strings" {
  let legacy : StepPlan = @json.from_json({
    "id": "old",
    "name": "Old",
    "run": "echo old",
    "shell": "",
    "working_directory": ".",
    "env": {},
    "timeout_minutes": 0,
  })
  assert_eq(legacy.uses, "")
  let action : StepPlan = { ..legacy, run: "", uses: "actions/checkout@v4", }
  assert_true(
    ToJson::to_json(action) is { "uses": String("actions/checkout@v4"), .. },
  )
  let decoded : StepPlan = @json.from_json(ToJson::to_json(action))
  assert_eq(decoded.uses, action.uses)
}

///|
test "MoonBit setup wire versions survive round trip while older steps still decode" {
  let legacy : StepPlan = @json.from_json({
    "id": "setup",
    "name": "Setup",
    "run": "",
    "uses": "moonhub/setup-moonbit@v1",
    "shell": "",
    "working_directory": ".",
    "env": {},
    "timeout_minutes": 0,
  })
  assert_eq(legacy.moonbit_version, "")
  let setup = { ..legacy, moonbit_version: "0.10.17+093cb8f9c", }
  let decoded : StepPlan = @json.from_json(ToJson::to_json(setup))
  assert_eq(decoded.moonbit_version, setup.moonbit_version)
  for raw in ["null", "true", "123", "[\"latest\"]"] {
    guard ToJson::to_json(setup) is Object(fields) else {
      fail("expected object")
    }
    fields["moonbit_version"] = @json.parse(raw)
    try {
      let _ : StepPlan = @json.from_json(ToJson::to_json(fields))
    } catch {
      _ => ()
    } noraise {
      _ => fail("accepted non-string MoonBit version")
    }
  }
}
