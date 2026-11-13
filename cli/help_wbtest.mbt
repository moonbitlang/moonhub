///|
test "every public command has focused help and usable examples" {
  for (group, actions) in command_groups() {
    for action in actions {
      guard command().parse_outcome(argv=[group, action, "--help"])
        is Help(text) else {
        fail("help failed for \{group} \{action}")
      }
      assert_true(!command_description(group, action).is_empty())
      let help = contextual_help(text)
      assert_true(help.contains("Examples and notes:"), msg=help)
      assert_true(
        help.contains("moonx hackwaly/moonhub/cmd/moonhub@latest"),
        msg=help,
      )
      for option in action_options(group, action) {
        assert_true(help.contains("--" + option), msg=help)
        assert_true(!option_description(option, group~).is_empty())
      }
    }
  }
  guard command().parse_outcome(argv=["auth", "login", "--help"]) is Help(help) else {
    fail("auth login help failed")
  }
  assert_true(!help.contains("--hunk-id"), msg=help)
  assert_true(!help.contains("--workflow"), msg=help)
  assert_true(contextual_help(help).contains("Account > Access tokens"))
}

///|
test "required input is rejected before authentication or HTTP" {
  for
    args in [
      ["issue", "view"],
      ["mr", "merge", "1"],
      ["mr", "create", "--title", "A title"],
      ["ci", "run", "--branch", "master"],
      ["variable", "delete"],
    ] {
    assert_true(command().parse_outcome(argv=args) is Failed(_))
  }
  let parsed = command().parse(argv=[
    "--version", "2", "--repo", "owner/demo", "mr", "merge", "1",
  ])
  assert_eq(option(parsed, "version"), Some("2"))
  assert_eq(option(parsed, "repo"), Some("owner/demo"))
}

///|
test "group help and input errors include command examples" {
  guard command().parse_outcome(argv=["help", "mr"]) is Help(text) else {
    fail("group help failed")
  }
  assert_true(contextual_help(text).contains("moonhub mr view 12 --json"))
  guard command().parse_outcome(argv=["mr", "merge", "1"]) is Failed(err) else {
    fail("missing version accepted")
  }
  assert_true(
    contextual_help(err.to_string()).contains("moonhub mr merge 12 --version 3"),
  )
}
