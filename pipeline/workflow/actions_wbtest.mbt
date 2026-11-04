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
