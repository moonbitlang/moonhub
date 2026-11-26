///|
fn parsed_command(argv : Array[String]) -> (String, @argparse.Matches) raise {
  match moonhub_command().parse_outcome(argv~, env={}) {
    Parsed({ subcommand: Some(command), .. }) => command
    _ => fail("not parsed as a command: \{argv.join(" ")}")
  }
}

///|
test "deployment invocations keep their commands" {
  // deploy/entrypoint.sh starts the Web service without a command name.
  for
    argv in [
      [
        "/data/repos", "--assets", "/app/assets", "--host", "0.0.0.0", "--port",
        "8080",
      ],
      ["--assets", "/app/assets", "/data/repos"],
    ] {
    let (name, options) = parsed_command(argv)
    assert_eq(name, "serve")
    assert_eq(single_value(options, "root"), Some("/data/repos"))
    assert_eq(single_value(options, "assets"), Some("/app/assets"))
  }
  // sshd AuthorizedKeysCommand, forced commands and Git hooks.
  let (name, options) = parsed_command([
    "ssh-authorized-key", "git", "ssh-ed25519", "AAAAC3Nza",
  ])
  assert_eq(name, "ssh-authorized-key")
  assert_eq(single_value(options, "key"), Some("AAAAC3Nza"))
  let (name, options) = parsed_command(["ssh-serve", "deploy:7"])
  assert_eq(name, "ssh-serve")
  assert_eq(single_value(options, "id"), Some("deploy:7"))
  let (name, options) = parsed_command([
    "ssh-ref-transaction", "7", "alice/demo", "push-1", "prepared",
  ])
  assert_eq(name, "ssh-ref-transaction")
  assert_eq(single_value(options, "phase"), Some("prepared"))
  let (name, options) = parsed_command([
    "provider", "--runner-server", "https://moonhub.test", "--runner-image", "runner:1",
  ])
  assert_eq(name, "provider")
  assert_eq(single_value(options, "runner-image"), Some("runner:1"))
  let (name, options) = parsed_command(["runner", "--probe-environment"])
  assert_eq(name, "runner")
  assert_true(options.flags.get("probe-environment") == Some(true))
}

///|
test "client and administrative commands parse their own arguments" {
  for argv in [["mr", "list", "--repo", "o/n"], ["mr", "--repo", "o/n", "list"]] {
    let (name, options) = parsed_command(argv)
    assert_eq(name, "mr")
    assert_eq(single_value(options, "repo"), Some("o/n"))
  }
  // Positionals belong to the subcommand; pipeline-rerun used to read them
  // from the root matches and always reported a missing run number.
  let (name, options) = parsed_command(["pipeline-rerun", "alice/demo", "3"])
  assert_eq(name, "pipeline-rerun")
  assert_eq(cli_value(options, "repository"), "alice/demo")
  assert_eq(cli_value(options, "number"), "3")
  assert_eq(cli_value(options, "db"), "moonhub.db")
  let (name, options) = parsed_command(["storage-check", "/etc/storage.json"])
  assert_eq(name, "storage-check")
  assert_eq(single_value(options, "config"), Some("/etc/storage.json"))
}

///|
test "help lists every public command and config checks have real help" {
  guard moonhub_command().parse_outcome(argv=["--help"], env={}) is Help(help) else {
    fail("root help failed")
  }
  for
    name in [
      "serve", "auth", "mr", "issue", "ci", "inbox", "ssh-key-add", "deploy-key-add",
      "repo-create", "pipeline-provider-ensure", "pipeline-rerun", "runner", "provider",
      "storage-check", "oidc-check",
    ] {
    assert_true(help.contains("  \{name} "), msg=name)
  }
  assert_true(!help.contains("ssh-serve"), msg=help)
  for
    argv in [
      ["help", "deploy-key-add"],
      ["deploy-key-add", "--help"],
      ["storage-check", "--help"],
      ["oidc-check", "--help"],
      ["serve", "--help"],
      ["mr", "list", "--help"],
    ] {
    assert_true(
      moonhub_command().parse_outcome(argv~, env={}) is Help(_),
      msg=argv.join(" "),
    )
  }
  guard moonhub_command().parse_outcome(argv=["mr", "create", "--help"], env={})
    is Help(help) else {
    fail("mr create help failed")
  }
  assert_true(@cli.contextual_help(help).contains("Examples and notes:"))
  assert_true(
    moonhub_command().parse_outcome(argv=["--version"], env={}) is Version(_),
  )
  assert_true(
    moonhub_command().parse_outcome(argv=["storage-check"], env={}) is Failed(_),
  )
}
