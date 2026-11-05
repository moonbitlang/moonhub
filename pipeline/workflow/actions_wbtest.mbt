///|
test "downloaded action inputs retain scalar types secret policy and environment precedence" {
  let source = basic_workflow.replace_all(
      old="run: echo hello",
      new="uses: actions/setup-node@v4",
    ) +
    "\n        with: {node-version: 24, check-latest: false, token: '${{ secrets.ACCESS_TOKEN }}'}\n        env: {PUBLIC: yes}"
  let step = parse(source).jobs[0].steps[0]
  assert_true(step.remote)
  assert_eq(step.inputs.get("node-version"), Some("24"))
  assert_eq(step.inputs.get("check-latest"), Some("false"))
  assert_eq(step.secret_env.get("INPUT_TOKEN"), Some("ACCESS_TOKEN"))
  assert_eq(step.inputs.get("token"), Some(""))
  assert_eq(step.env.get("PUBLIC"), Some("yes"))
  let decoded : Step = @json.from_json(ToJson::to_json(step))
  assert_true(decoded.remote)
  assert_eq(decoded.secret_env, step.secret_env)
  for
    action in [
      "owner/repo/sub/action@refs/heads/main", "actions/checkout@v6", "./.github/actions/build",
    ] {
    assert_true(
      parse(
        basic_workflow.replace_all(old="run: echo hello", new="uses: " + action),
      ).jobs[0].steps[0].remote,
    )
  }
}

///|
test "downloaded action validation rejects malformed refs duplicate inputs and mixed scripts" {
  for
    action in [
      "owner/repo", "https://github.com/owner/repo@v1", "owner/repo@--help", "owner/repo@x;echo",
      "owner/repo@../x", "owner/repo/../other@v1", "./../outside",
    ] {
    expect_invalid(
      basic_workflow.replace_all(old="run: echo hello", new="uses: " + action),
      "uses",
    )
  }
  let source = basic_workflow.replace_all(
    old="run: echo hello",
    new="uses: actions/setup-node@v4",
  )
  for
    field in [
      "with: {Token: a, token: b}", "with: {node-version: []}", "with: {'bad.input': value}",
      "run: echo bad", "shell: bash", "working-directory: src",
    ] {
    try ignore(parse(source + "\n        " + field)) catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("accepted invalid remote action")
    }
  }
}

///|
test "Windows jobs preserve platform selection and PowerShell defaults" {
  let source =
    #|name: Windows
    #|on: push
    #|jobs:
    #|  build:
    #|    runs-on: [self-hosted, windows, x64]
    #|    defaults:
    #|      run:
    #|        shell: pwsh
    #|    steps:
    #|      - run: Write-Output 'hello'
  let workflow = parse(source)
  assert_eq(workflow.jobs[0].runs_on, ["self-hosted", "windows", "x64"])
  assert_eq(workflow.jobs[0].steps[0].shell, Some("pwsh"))
}

///|
test "Windows environment precedence ignores case and Linux retains it" {
  let source =
    #|on: workflow_dispatch
    #|env: {Greeting: workflow}
    #|jobs:
    #|  build:
    #|    runs-on: [self-hosted, windows]
    #|    env: {GREETING: job}
    #|    steps:
    #|      - run: Write-Output hello
    #|        env: {greeting: step}
  let windows = parse(source)
  assert_eq(windows.jobs[0].steps[0].env, { "GREETING": "step" })
  assert_eq(windows.jobs[0].steps[0].env_overrides, ["GREETING"])
  let linux = parse(source.replace_all(old="windows", new="linux"))
  assert_eq(linux.jobs[0].steps[0].env.length(), 3)
  expect_invalid(
    source.replace_all(old="{greeting: step}", new="{greeting: a, GREETING: b}"),
    "unique ignoring case",
  )
  expect_invalid(
    source.replace_all(old="{greeting: step}", new="{Node_Options: bad}"),
    "reserved",
  )
}

///|
test "PowerShell requires Windows after workflow job and step defaults resolve" {
  let source =
    #|on: workflow_dispatch
    #|jobs:
    #|  build:
    #|    runs-on: [self-hosted, linux]
    #|    steps:
    #|      - run: echo hello
  for
    workflow in [
      source + "\n        shell: pwsh",
      source.replace_all(
        old="jobs:",
        new="defaults:\n  run: {shell: pwsh}\njobs:",
      ),
      source.replace_all(
        old="    steps:",
        new="    defaults:\n      run: {shell: pwsh}\n    steps:",
      ),
      source.replace_all(old="[self-hosted, linux]", new="self-hosted") +
      "\n        shell: pwsh",
    ] {
    expect_invalid(workflow, "pwsh requires Windows")
    let windows = workflow
      .replace_all(old="[self-hosted, linux]", new="[self-hosted, windows]")
      .replace_all(
        old="runs-on: self-hosted",
        new="runs-on: [self-hosted, windows]",
      )
    assert_eq(parse(windows).jobs[0].steps[0].shell, Some("pwsh"))
  }
  let overridden = source.replace_all(
      old="jobs:",
      new="defaults:\n  run: {shell: pwsh}\njobs:",
    ) +
    "\n        shell: bash"
  assert_eq(parse(overridden).jobs[0].steps[0].shell, Some("bash"))
}
