///|
test "wire state uses decimal strings for Int64 values and scalar conclusions" {
  let state : LeaseState = {
    version: 1,
    execution_id: "",
    attempt_id: 42L,
    state: "running",
    lease_until_ms: 60000L,
    server_time_ms: 0L,
    deadline_ms: 60000L,
    cancel_requested: false,
    log_sequence: 1L,
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
}

///|
test "wire Int64 identifiers preserve values beyond JavaScript integer precision" {
  let state : LeaseState = {
    version: 1,
    execution_id: "",
    attempt_id: 9007199254740993L,
    state: "leased",
    lease_until_ms: 60000L,
    server_time_ms: 0L,
    deadline_ms: 0L,
    cancel_requested: false,
    log_sequence: 0L,
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
