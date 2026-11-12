///|
async test "original openseek Tools SDK workflow parses without rewriting" {
  // openseek 9e8b15a59b40b62b018e53b4b85a3bea971e1acf, verbatim fixture.
  let source = @fs.read_file(
    "pipeline/workflow/fixtures/openseek-tools-sdk.yml",
  ).text()
  let workflow = parse(source)
  assert_eq(workflow.name, "Tools SDK")
  assert_eq(workflow.jobs.length(), 1)
  assert_eq(workflow.jobs[0].runs_on, [
    "self-hosted", "linux", "x64", "ubuntu-24.04",
  ])
  assert_true(workflow.jobs[0].contents_read)
  assert_eq(workflow.jobs[0].steps[0].uses, Some("actions/checkout@v5"))
  assert_true(workflow.jobs[0].steps[0].remote)
  assert_eq(workflow.jobs[0].steps.length(), 8)
  let trigger = triggers(source)
  for
    path in [
      "desktop/.moonbit-version", "tools_sdk/src/check.mbt", ".github/workflows/tools-sdk.yml",
    ] {
    assert_true(trigger.matches_push("main", paths=Some([path])))
    assert_true(
      trigger.matches_pull_request(
        "synchronize",
        branch="main",
        paths=Some([path]),
      ),
    )
  }
  assert_false(
    trigger.matches_push("feature", paths=Some(["tools_sdk/main.mbt"])),
  )
  assert_false(trigger.matches_push("main", paths=Some(["README.md"])))
  assert_false(
    trigger.matches_pull_request(
      "opened",
      branch="main",
      paths=Some(["desktop/app/main.mbt"]),
    ),
  )
}

///|
test "filter globs support separators recursive directories classes escapes and quantifiers" {
  for
    (pattern, value, expected) in [
      ("tools_sdk/**", "tools_sdk/src/main.mbt", true),
      ("tools_sdk/*", "tools_sdk/src/main.mbt", false),
      ("**/README.md", "README.md", true),
      ("**/README.md", "docs/README.md", true),
      ("a/**/b", "a/b", true),
      ("a/**/b", "a/c/d/b", true),
      ("a/**/b", "a/c/notb", false),
      ("v[0-9]+.[0-9]+", "v12.3", true),
      ("v[0-9]+", "v", false),
      ("releases/ab?", "releases/a", true),
      ("releases/ab?", "releases/ab", true),
      ("releases/ab?", "releases/ac", false),
      ("feature/\\*literal", "feature/*literal", true),
      ("README.md", "readme.md", false),
    ] {
    assert_eq(filter_match(pattern, value), expected, msg=pattern + ":" + value)
  }
  for
    pattern in [
      "[",
      "[]",
      "[z-a]",
      "[a-Z]",
      "*+",
      "?x",
      "abc\\",
      "x".repeat(257),
    ] {
    try ignore(filter_tokens(pattern)) catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("accepted malformed glob")
    }
  }
}

///|
test "filters combine branches paths ordered negation and ignores" {
  let source = basic_workflow.replace_all(
    old="on: workflow_dispatch",
    new="on: {push: {branches: ['release/**', '!release/private/**'], paths: ['src/**', '!src/docs/**', 'src/docs/keep.md']}, pull_request: {branches: [main], paths-ignore: ['docs/**']}}",
  )
  let trigger = triggers(source)
  assert_true(trigger.matches_push("release/v1", paths=Some(["src/main.mbt"])))
  assert_false(
    trigger.matches_push("release/private/x", paths=Some(["src/main.mbt"])),
  )
  assert_false(
    trigger.matches_push("release/v1", paths=Some(["src/docs/readme.md"])),
  )
  assert_true(
    trigger.matches_push("release/v1", paths=Some(["src/docs/keep.md"])),
  )
  assert_false(trigger.matches_push("release/v1", paths=Some([])))
  assert_true(trigger.matches_push("release/v1", paths=None))
  assert_true(
    trigger.matches_pull_request(
      "opened",
      branch="main",
      paths=Some(["docs/a", "src/a"]),
    ),
  )
  assert_false(
    trigger.matches_pull_request(
      "opened",
      branch="main",
      paths=Some(["docs/a"]),
    ),
  )
  assert_false(
    trigger.matches_pull_request(
      "opened",
      branch="other",
      paths=Some(["src/a"]),
    ),
  )
  for
    options in [
      "{paths: [a], paths-ignore: [b]}", "{branches: [a], branches-ignore: [b]}",
      "{paths: ['!only-negative']}", "{paths-ignore: ['!negative']}", "{paths: []}",
      "{paths: ['[']}",
    ] {
    expect_invalid(
      basic_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: {push: " + options + "}",
      ),
      "",
    )
  }
}

///|
test "contents permissions inherit and override without granting other scopes" {
  let restricted = "permissions: {}\n" + basic_workflow
  assert_false(parse(restricted).jobs[0].contents_read)
  assert_true(
    parse(restricted + "\n    permissions: {contents: read}").jobs[0].contents_read,
  )
  assert_false(
    parse(
      "permissions: {contents: read}\n" +
      basic_workflow +
      "\n    permissions: {contents: none}",
    ).jobs[0].contents_read,
  )
  assert_true(parse(basic_workflow).jobs[0].contents_read)
  for permission in ["read-all", "write-all", "{id-token: read}"] {
    expect_invalid(
      "permissions: " + permission + "\n" + basic_workflow,
      "permissions",
    )
  }
  let old = ToJson::to_json(parse(basic_workflow))
    .stringify()
    .replace_all(old="\"contents_read\":true,", new="")
  let restored : Workflow = @json.from_json(@json.parse(old))
  assert_true(restored.jobs[0].contents_read)
}

///|
test "repeated include patterns preserve ordered re-inclusion and huge diffs run conservatively" {
  let trigger = triggers(
    basic_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {push: {paths: ['src/**', '!src/private/**', 'src/**']}}",
    ),
  )
  assert_true(trigger.matches_push("main", paths=Some(["src/private/a"])))
  let large = Array::make(10000, "unrelated/" + "x".repeat(1000))
  assert_true(trigger.matches_push("main", paths=Some(large)))
}
