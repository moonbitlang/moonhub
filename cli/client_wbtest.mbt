///|
test "CLI server validation rejects credential leaking destinations and malformed numbers" {
  assert_eq(
    validate_server("https://moonhub.example/", false),
    "https://moonhub.example",
  )
  assert_eq(
    validate_server("http://127.0.0.1:8080", true),
    "http://127.0.0.1:8080",
  )
  for
    server in [
      "http://example.com", "https://user@example.com", "https://example.com/path",
      "https://example.com?query", "https://example.com#frag", "https://example.com\n",
    ] {
    try validate_server(server, false) catch {
      Invalid(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid server")
    }
  }
  assert_eq(escape("a b/中"), "a%20b%2F%E4%B8%AD")
  for id in ["0", "01", "-1", "9223372036854775808", "1x"] {
    try decimal(id) catch {
      Invalid(_) => ()
      err => raise err
    } noraise {
      _ => fail("invalid id")
    }
  }
}

///|
test "nested collaboration commands retain global options" {
  let parsed = command().parse(argv=[
    "mr", "review", "3", "--server", "https://moonhub.example", "--repo", "compiler/moonhub",
    "--version", "2", "--decision", "approved", "--json",
  ])
  assert_eq(option(parsed, "repo"), Some("compiler/moonhub"))
  assert_eq(option(parsed, "version"), Some("2"))
  assert_true(parsed.flags.get("json") == Some(true))
  let (group, options) = parsed.subcommand.unwrap()
  assert_eq(group, "mr")
  let (action, options) = options.subcommand.unwrap()
  assert_eq(action, "review")
  assert_eq(option(options, "number"), Some("3"))
}

///|
test "MR edit and comment lifecycle commands retain explicit revisions" {
  for action in ["edit", "delete-comment", "restore-comment"] {
    let parsed = command().parse(argv=[
      "mr", action, "10", "--edit-version", "2", "--version", "1", "--comment", "9223372036854775807",
      "--title", "English title", "--json",
    ])
    assert_eq(option(parsed, "edit-version"), Some("2"))
    assert_eq(option(parsed, "version"), Some("1"))
    assert_eq(option(parsed, "comment"), Some("9223372036854775807"))
    let (_, group) = parsed.subcommand.unwrap()
    let (name, options) = group.subcommand.unwrap()
    assert_eq(name, action)
    assert_eq(option(options, "number"), Some("10"))
  }
}

///|
test "discussion commands retain independent discussion and state IDs" {
  for
    action in [
      "discussions", "reply", "resolve-discussion", "reopen-discussion",
    ] {
    let parsed = command().parse(argv=[
      "mr", action, "10", "--discussion", "9223372036854775807", "--state-version",
      "2", "--filter", "unresolved", "--page", "3",
    ])
    assert_eq(option(parsed, "discussion"), Some("9223372036854775807"))
    assert_eq(option(parsed, "state-version"), Some("2"))
    assert_eq(option(parsed, "filter"), Some("unresolved"))
    assert_eq(option(parsed, "page"), Some("3"))
  }
}

///|
test "repository inference matches only the configured server and terminal output strips controls" {
  let server = "https://moonhub.example"
  assert_eq(
    remote_repo("ssh://git@moonhub.example:12222/compiler/moonhub.git", server),
    Some("compiler/moonhub"),
  )
  assert_eq(
    remote_repo("git@moonhub.example:compiler/moonhub.git", server),
    Some("compiler/moonhub"),
  )
  assert_eq(remote_repo("git@github.com:compiler/moonhub.git", server), None)
  assert_eq(
    remote_repo("https://moonhub.example/compiler/moonhub.git", server),
    Some("compiler/moonhub"),
  )
  assert_eq(terminal_text("before\u{001b}[31m\nafter"), "before [31m after")
}
