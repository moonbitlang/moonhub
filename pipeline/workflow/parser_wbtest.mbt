///|
let basic_workflow : String =
  #|name: Build
  #|on: workflow_dispatch
  #|jobs:
  #|  build:
  #|    runs-on: [self-hosted, linux]
  #|    steps:
  #|      - run: echo hello

///|
fn expect_invalid(source : String, fragment : String) -> Unit raise {
  try ignore(parse(source)) catch {
    InvalidWorkflow(message) =>
      assert_true(message.contains(fragment), msg=message)
  } noraise {
    _ => fail("accepted invalid workflow: \{fragment}")
  }
}

///|
test "workflow scalar trigger and normalized plan round trip" {
  let workflow = parse(basic_workflow)
  assert_eq(workflow.name, "Build")
  assert_eq(workflow.jobs.length(), 1)
  assert_eq(workflow.jobs[0].timeout_minutes, 360)
  let step = workflow.jobs[0].steps[0]
  assert_eq(step.id, "step_1")
  assert_eq(step.run, "echo hello")
  assert_eq(step.uses, None)
  assert_eq(step.shell, None)
  assert_eq(step.working_directory, ".")
  let restored : Workflow = @json.from_json(ToJson::to_json(workflow))
  assert_eq(ToJson::to_json(restored), ToJson::to_json(workflow))
  for
    trigger in [
      "[workflow_dispatch]", "{workflow_dispatch: null}", "{workflow_dispatch: {}}",
      "pull_request", "{pull_request: null}",
    ] {
    assert_eq(
      parse(
        basic_workflow.replace_all(
          old="on: workflow_dispatch",
          new="on: \{trigger}",
        ),
      ).jobs.length(),
      1,
    )
  }
}

///|
test "workflow job and step env and defaults have explicit precedence" {
  // The env/defaults precedence scenario follows actrun's docs compatibility fixtures.
  let workflow = parse(
    (
      #|on: workflow_dispatch
      #|env: {LEVEL: workflow, COUNT: 42, FLAG: true, EMPTY: "", TEXT: 'on'}
      #|defaults:
      #|  run: {shell: sh, working-directory: src}
      #|jobs:
      #|  build:
      #|    runs-on: self-hosted
      #|    timeout-minutes: 20
      #|    env: {LEVEL: job, JOB: yes}
      #|    defaults:
      #|      run: {shell: bash}
      #|    steps:
      #|      - id: first
      #|        run: echo first
      #|        env: {LEVEL: step}
      #|        working-directory: other
      #|        timeout-minutes: 2
      #|      - run: echo second
    ),
  )
  let job = workflow.jobs[0]
  let first = job.steps[0]
  let second = job.steps[1]
  assert_eq(job.timeout_minutes, 20)
  assert_eq(first.shell, Some("bash"))
  assert_eq(first.working_directory, "other")
  assert_eq(first.timeout_minutes, Some(2))
  assert_eq(first.env.get("LEVEL"), Some("step"))
  assert_eq(first.env.get("COUNT"), Some("42"))
  assert_eq(first.env.get("FLAG"), Some("true"))
  assert_eq(first.env.get("EMPTY"), Some(""))
  assert_eq(first.env.get("TEXT"), Some("on"))
  assert_eq(second.working_directory, "src")
  assert_eq(second.timeout_minutes, None)
  assert_eq(second.env.get("LEVEL"), Some("job"))
}

///|
test "YAML multiline scripts comments quotes and chomping remain intact" {
  let workflow = parse(
    (
      #|name: "Build #1" # comment
      #|on: workflow_dispatch
      #|jobs:
      #|  build:
      #|    runs-on: self-hosted
      #|    steps:
      #|      - run: |
      #|          printf '%s\n' '# not a comment'
      #|          echo "on: true"
      #|      - run: >-
      #|          echo one
      #|          two
      #|      - run: 'echo ''quoted'' # literal'
    ),
  )
  assert_eq(workflow.name, "Build #1")
  assert_eq(
    workflow.jobs[0].steps[0].run,
    "printf '%s\\n' '# not a comment'\necho \"on: true\"\n",
  )
  assert_eq(workflow.jobs[0].steps[1].run, "echo one two")
  assert_eq(workflow.jobs[0].steps[2].run, "echo 'quoted' # literal")
}

///|
test "pull request workflows accept the built-in checkout action" {
  let workflow = parse(
    (
      #|name: MoonBit CI
      #|on:
      #|  pull_request:
      #|    types: [opened, synchronize, reopened]
      #|jobs:
      #|  test:
      #|    runs-on: [self-hosted, linux]
      #|    steps:
      #|      - uses: actions/checkout@v4
      #|      - run: moon test --target native --strip -j 1
    ),
  )
  assert_eq(workflow.jobs[0].steps[0].run, "")
  assert_eq(workflow.jobs[0].steps[0].uses, Some("actions/checkout@v4"))
  assert_eq(workflow.jobs[0].steps[1].uses, None)
  let trigger = triggers(
    (
      #|on:
      #|  pull_request:
      #|    types: [opened, synchronize, reopened]
      #|jobs:
      #|  test:
      #|    runs-on: self-hosted
      #|    steps:
      #|      - run: echo test
    ),
  )
  assert_true(trigger.pull_request)
  assert_true(trigger.matches_pull_request("opened"))
  assert_true(trigger.matches_pull_request("synchronize"))
  assert_false(trigger.matches_pull_request("closed"))
  expect_invalid(
    (
      #|on: pull_request
      #|jobs:
      #|  test:
      #|    runs-on: self-hosted
      #|    steps:
      #|      - uses: owner/action@v1
    ),
    "built-in checkout",
  )
  expect_invalid(
    (
      #|on: pull_request
      #|jobs:
      #|  test:
      #|    runs-on: self-hosted
      #|    steps:
      #|      - uses: actions/checkout@main
    ),
    "built-in checkout",
  )
}

///|
test "unsupported execution semantics fail closed at every mapping level" {
  for
    (field, fragment) in [
      ("permissions: read-all\n", "workflow.permissions"),
      ("concurrency: deploy\n", "workflow.concurrency"),
      ("unknown: true\n", "workflow.unknown"),
    ] {
    expect_invalid(field + basic_workflow, fragment)
  }
  for
    field in [
      "if: false", "container: alpine", "services: {}", "strategy: {}", "continue-on-error: true",
      "outputs: {}",
    ] {
    expect_invalid(basic_workflow + "\n    " + field, "not supported")
  }
  for
    field in ["if: false", "continue-on-error: true", "with: {}", "unknown: 1"] {
    expect_invalid(basic_workflow + "\n        " + field, "not supported")
  }
  expect_invalid(
    basic_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {workflow_dispatch: {inputs: {}}}",
    ),
    "inputs are not supported",
  )
  expect_invalid(
    basic_workflow.replace_all(
      old="echo hello",
      new="echo '${{ secrets.TOKEN }}'",
    ),
    "expressions",
  )
  expect_invalid(
    basic_workflow.replace_all(
      old="name: Build",
      new="name: '${{ github.ref }}'",
    ),
    "expressions",
  )
  expect_invalid(
    basic_workflow + "\n    env: {TOKEN: 'prefix-${{ secrets.TOKEN }}'}",
    "expressions",
  )
}

///|
test "YAML duplicate keys empty keys aliases tags and extra documents are rejected" {
  expect_invalid("name: Other\n" + basic_workflow, "duplicate")
  expect_invalid(basic_workflow + "\n        run: echo other", "duplicate")
  expect_invalid(basic_workflow + "\n    env: {X: 1, X: 2}", "duplicate")
  expect_invalid(basic_workflow + "\n'': ignored", "empty keys")
  expect_invalid(basic_workflow + "\n---\nname: ignored", "one YAML document")
  expect_invalid(
    basic_workflow.replace_all(old="name: Build", new="name: &name Build"),
    "anchors",
  )
  expect_invalid(
    basic_workflow.replace_all(old="name: Build", new="name: !!str Build"),
    "tags",
  )
  expect_invalid(basic_workflow + "\n    env: {<<: {X: value}}", "merge keys")
  expect_invalid(
    basic_workflow.replace_all(old="name: Build", new="name: *missing"),
    "invalid YAML",
  )
  expect_invalid("", "one YAML document")
}

///|
test "structural limits apply before workflow field mapping" {
  expect_invalid("#" + "x".repeat(max_source_bytes), "64 KiB")
  expect_invalid("#" + "a".repeat(max_source_bytes - 1) + "\n", "64 KiB")
  expect_invalid(basic_workflow + "\u{0000}", "NUL")
  expect_invalid(
    basic_workflow.replace_all(old="echo hello", new="\"echo \\0\""),
    "NUL",
  )
  expect_invalid("value: " + "[".repeat(33) + "0" + "]".repeat(33), "nesting")
  expect_invalid("- ".repeat(10000) + "0", "nesting")
  expect_invalid("value: [" + "0,".repeat(8200) + "0]", "8192 nodes")
  let expanded = "on: workflow_dispatch\nenv: {LARGE: '" +
    "x".repeat(32768) +
    "'}\njobs:\n  build:\n    runs-on: self-hosted\n    steps:\n" +
    "      - run: echo test\n".repeat(64)
  expect_invalid(expanded, "normalized workflow")
}

///|
test "job dependency validation rejects unknown self duplicate and cyclic edges" {
  for need in ["missing", "build"] {
    expect_invalid(
      basic_workflow + "\n    needs: " + need,
      "unknown job or itself",
    )
  }
  expect_invalid(basic_workflow + "\n    needs: [other, other]", "duplicate")
  let two_jobs = basic_workflow +
    "\n  test:\n    runs-on: self-hosted\n    needs: build\n    steps:\n      - run: echo test"
  let workflow = parse(two_jobs)
  assert_eq(workflow.jobs.length(), 2)
  let test_job = workflow.jobs
    .iter()
    .find_first(job => job.id == "test")
    .unwrap()
  assert_eq(test_job.needs, ["build"])
  expect_invalid(
    two_jobs.replace_all(old="  build:\n", new="  build:\n    needs: test\n"),
    "cycle",
  )
}

///|
test "paths shell identifiers reserved variables and timeout types are validated" {
  for path in ["../outside", "/tmp", "a/../../b", "a//b", "C:\\temp"] {
    expect_invalid(
      basic_workflow + "\n        working-directory: '" + path + "'",
      "workspace path",
    )
  }
  for value in ["0", "-1", "361", "true", "'5'", "1.5"] {
    expect_invalid(
      basic_workflow + "\n        timeout-minutes: " + value,
      "integer",
    )
  }
  expect_invalid(basic_workflow + "\n        shell: 'bash {0}'", "bash and sh")
  expect_invalid(basic_workflow + "\n        id: 12", "string")
  expect_invalid(basic_workflow + "\n        id: invalid.id", "step id")
  expect_invalid(
    basic_workflow + "\n      - id: step_1\n        run: echo again",
    "duplicate step id",
  )
  for
    key in [
      "MOONHUB_TOKEN", "GITHUB_TOKEN", "RUNNER_TEMP", "bad-name", "1invalid",
    ] {
    expect_invalid(
      basic_workflow + "\n        env: {" + key + ": secret}",
      "reserved variable",
    )
  }
  expect_invalid(
    basic_workflow.replace_all(old="[self-hosted, linux]", new="ubuntu-latest"),
    "self-hosted",
  )
  expect_invalid(
    basic_workflow.replace_all(
      old="[self-hosted, linux]",
      new="[self-hosted, Windows]",
    ),
    "Linux",
  )
  expect_invalid(
    basic_workflow.replace_all(
      old="[self-hosted, linux]",
      new="[self-hosted, Linux, linux]",
    ),
    "duplicate label",
  )
  expect_invalid(
    basic_workflow.replace_all(old="echo hello", new="[echo, hello]"),
    "string",
  )
  expect_invalid(
    basic_workflow + "\n    env: {VALUE: {nested: object}}",
    "scalar",
  )
}

///|
test "checkout rejects mixed unsupported and repeated actions and keeps legacy snapshots readable" {
  let action = basic_workflow.replace_all(
    old="run: echo hello",
    new="uses: moonhub/checkout@v1",
  )
  assert_eq(parse(action).jobs[0].steps[0].uses, Some("moonhub/checkout@v1"))
  for
    field in [
      "run: echo unsafe", "with: {}", "shell: bash", "working-directory: src", "env: {X: y}",
    ] {
    expect_invalid(
      action + "\n        " + field,
      if field.has_prefix("run:") {
        "exactly one"
      } else {
        "not supported"
      },
    )
  }
  expect_invalid(action + "\n      - uses: actions/checkout@v4", "one checkout")
  expect_invalid(
    basic_workflow.replace_all(old="echo hello", new="'   '"),
    "nonempty",
  )
  let legacy : Step = @json.from_json({
    "id": "old",
    "name": "Old",
    "run": "echo old",
    "working_directory": ".",
    "env": {},
  })
  assert_eq(legacy.uses, None)
  assert_eq(legacy.moonbit_version, None)
  assert_eq(legacy.shell, None)
  assert_eq(legacy.timeout_minutes, None)
  let workflow = parse(action)
  let restored : Workflow = @json.from_json(ToJson::to_json(workflow))
  assert_eq(restored.jobs[0].steps[0].uses, Some("moonhub/checkout@v1"))
}

///|
test "MoonBit setup normalizes inputs and round trips with checkout in either order" {
  let source = basic_workflow.replace_all(
    old="run: echo hello",
    new="uses: moonhub/setup-moonbit@v1",
  )
  assert_eq(parse(source).jobs[0].steps[0].moonbit_version, Some("latest"))
  assert_eq(
    parse(source + "\n        with: {}").jobs[0].steps[0].moonbit_version,
    Some("latest"),
  )
  for
    (input, expected) in [
      ("stable", "latest"),
      ("latest", "latest"),
      ("bleeding", "nightly"),
      ("nightly", "nightly"),
      ("pre-release", "pre-release"),
      ("0.10.17+093cb8f9c", "0.10.17+093cb8f9c"),
    ] {
    let workflow = parse(
      source +
      "\n        with: {version: '\{input}'}\n      - uses: moonhub/checkout@v1",
    )
    let setup = workflow.jobs[0].steps[0]
    assert_eq(setup.moonbit_version, Some(expected))
    assert_eq(setup.run, "")
    assert_eq(setup.shell, None)
    assert_eq(setup.working_directory, ".")
    assert_true(setup.env.is_empty())
    let restored : Workflow = @json.from_json(ToJson::to_json(workflow))
    assert_eq(ToJson::to_json(restored), ToJson::to_json(workflow))
  }
  let checkout_first = source.replace_all(
    old="uses: moonhub/setup-moonbit@v1",
    new="uses: actions/checkout@v4\n      - uses: moonhub/setup-moonbit@v1",
  )
  assert_eq(
    parse(checkout_first).jobs[0].steps[1].moonbit_version,
    Some("latest"),
  )
  expect_invalid(
    checkout_first + "\n      - uses: moonhub/checkout@v1",
    "one checkout",
  )
}

///|
test "MoonBit setup rejects arbitrary inputs expressions unsafe versions and mixed semantics" {
  let source = basic_workflow.replace_all(
    old="run: echo hello",
    new="uses: moonhub/setup-moonbit@v1",
  )
  for
    version in [
      "",
      " stable",
      "main",
      "../nightly",
      "--help",
      "0.1;touch injected",
      "$(id)",
      "0.1/other",
      "0.1?x=1",
      "0.1#x",
      "0.1..2",
      "0.1%2fother",
      "0.1'quote",
      "0." + "a".repeat(128),
    ] {
    expect_invalid(
      source + "\n        with: {version: \"\{version}\"}",
      "version",
    )
  }
  expect_invalid(
    source + "\n        with: {version: '${{ github.sha }}'}",
    "expressions",
  )
  for
    inputs in [
      "{version: true}", "{version: 123}", "{version: null}", "{version: []}", "{version: {}}",
      "{version: stable, unknown: true}", "[]", "null",
    ] {
    expect_invalid(source + "\n        with: \{inputs}", "with")
  }
  for
    field in [
      "env: {X: y}", "shell: bash", "working-directory: src", "run: echo mixed",
    ] {
    expect_invalid(
      source + "\n        \{field}",
      if field.has_prefix("run:") {
        "exactly one"
      } else {
        "not supported"
      },
    )
  }
  expect_invalid(source.replace_all(old="@v1", new="@main"), "built-in")
  expect_invalid(
    source.replace_all(
      old="moonhub/setup-moonbit@v1",
      new="moonbit-community/setup-moonbit@main",
    ),
    "built-in",
  )
}
