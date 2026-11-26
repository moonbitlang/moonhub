///|
test "repo commands parse the repository and default to private" {
  let created = command().parse(argv=[
    "repo", "create", "--repo", "alice/hello-moon",
  ])
  assert_eq(option(created, "repo"), Some("alice/hello-moon"))
  assert_eq(option(created, "visibility"), Some("private"))
  let public = command().parse(argv=[
    "repo", "create", "--repo", "alice/hello-moon", "--visibility", "public",
  ])
  assert_eq(option(public, "visibility"), Some("public"))
  let viewed = command().parse(argv=["repo", "view", "--repo", "alice/demo"])
  assert_eq(option(viewed, "repo"), Some("alice/demo"))
  guard command().parse_outcome(argv=["repo", "create", "--help"]) is Help(help) else {
    fail("repo create help failed")
  }
  let help = contextual_help(help)
  assert_true(help.contains("--visibility"), msg=help)
  assert_true(help.contains("git push -u origin main"), msg=help)
}

///|
test "the native executable dispatches every client command group" {
  for (group, _) in command_groups() {
    assert_true(is_client_command(group), msg=group)
  }
  assert_true(is_client_command("help"))
  // Server administration commands keep their own parser.
  for name in ["repo-create", "ssh-key-add", "storage-check", "--assets"] {
    assert_true(!is_client_command(name), msg=name)
  }
}
