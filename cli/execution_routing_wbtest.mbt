///|
test "execution environment and repository retry commands expose explicit revisions" {
  let parsed = command().parse(argv=[
    "environment", "set", "ubuntu-x64", "--body-file", "/tmp/environment.json", "--version",
    "0",
  ])
  let (_, group) = parsed.subcommand.unwrap()
  let (_, options) = group.subcommand.unwrap()
  assert_eq(option(options, "name"), Some("ubuntu-x64"))
  assert_eq(option(parsed, "version"), Some("0"))
  for
    args in [
      ["environment", "list", "--json"],
      ["ci", "policy", "--json"],
      ["ci", "set-policy", "--version", "1", "--mode", "capability-retry"],
      ["ci", "execution", "12", "--json"],
    ] {
    ignore(command().parse(argv=args[:]))
  }
}
