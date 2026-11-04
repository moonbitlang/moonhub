///|
let mr_context : RunContext = {
  repository: "alice/demo",
  sha: "a".repeat(40),
  event_name: "pull_request",
  head_ref: "feature/one",
  base_ref: "master",
}

///|
test "env references resolve once after workflow job step precedence" {
  let source =
    #|on: pull_request
    #|env:
    #|  REPO: ${{ github.repository }}
    #|  LEVEL: ${{ github.event_name }}
    #|jobs:
    #|  test:
    #|    runs-on: self-hosted
    #|    env:
    #|      LEVEL: ${{ github.head_ref }}
    #|      SHA: prefix-${{github.sha}}-${{ github.sha }}
    #|    steps:
    #|      - run: echo test
    #|        env:
    #|          LEVEL: ${{ github.base_ref }}
    #|          STATIC: literal
    #|      - run: echo second
  let parsed = parse(source)
  assert_eq(
    parsed.jobs[0].steps[0].env.get("REPO"),
    Some("${{ github.repository }}"),
  )
  let resolved = resolve_context(parsed, mr_context)
  let first = resolved.jobs[0].steps[0]
  assert_eq(first.env.get("REPO"), Some("alice/demo"))
  assert_eq(first.env.get("LEVEL"), Some("master"))
  assert_eq(
    first.env.get("SHA"),
    Some("prefix-" + mr_context.sha + "-" + mr_context.sha),
  )
  assert_eq(first.env.get("STATIC"), Some("literal"))
  assert_eq(resolved.jobs[0].steps[1].env.get("LEVEL"), Some("feature/one"))
  assert_eq(first.run, "echo test")
}

///|
test "runtime expressions retain templates while invalid interpolation is rejected" {
  for expression in ["${{ secrets.TOKEN }}suffix", "${{ }}", "${{ github.sha"] {
    expect_invalid(
      basic_workflow +
      "\n        env: {VALUE: \"" +
      expression.replace_all(old="\"", new="\\\"") +
      "\"}",
      "expression",
    )
  }
  let dynamic = parse(
    basic_workflow.replace_all(
      old="echo hello",
      new="echo '${{ steps.first.outputs.value }}'",
    ),
  )
  assert_true(dynamic.jobs[0].steps[0].templates.contains("run"))
  expect_invalid(
    basic_workflow.replace_all(
      old="name: Build",
      new="name: '${{ github.sha }}'",
    ),
    "expressions",
  )
  expect_invalid(
    basic_workflow + "\n        working-directory: '${{ github.head_ref }}'",
    "expressions",
  )
  expect_invalid(
    basic_workflow + "\n        env: {GITHUB_SHA: '${{ github.sha }}'}",
    "reserved",
  )
}

///|
test "metadata interpolation is not recursive and missing MR fields are empty" {
  let workflow = parse(
    basic_workflow +
    "\n        env: {HEAD: '${{ github.head_ref }}', BASE: '${{ github.base_ref }}', EVENT: '${{github.event_name}}'}",
  )
  let hostile = "feature/$(touch-injected);`echo-danger`-${{ secrets.TOKEN }}"
  let resolved = resolve_context(workflow, { ..mr_context, head_ref: hostile, })
  assert_eq(resolved.jobs[0].steps[0].env.get("HEAD"), Some(hostile))
  assert_eq(resolved.jobs[0].steps[0].run, "echo hello")
  for event in ["push", "workflow_dispatch"] {
    let resolved = resolve_context(workflow, {
      ..mr_context,
      event_name: event,
      head_ref: "",
      base_ref: "",
    })
    assert_eq(resolved.jobs[0].steps[0].env.get("HEAD"), Some(""))
    assert_eq(resolved.jobs[0].steps[0].env.get("BASE"), Some(""))
    assert_eq(resolved.jobs[0].steps[0].env.get("EVENT"), Some(event))
  }
}

///|
test "resolved env size and normalized plan limits remain bounded" {
  let workflow = parse(
    basic_workflow + "\n        env: {HEAD: '${{ github.head_ref }}'}",
  )
  for value in ["x".repeat(65537), "bad\u{0000}value"] {
    try
      ignore(resolve_context(workflow, { ..mr_context, head_ref: value, }))
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("unsafe resolved env value accepted")
    }
  }
  let source = basic_workflow +
    "\n        env: {HEAD: '${{ github.head_ref }}'}" +
    "\n      - run: echo next\n        env: {HEAD: '${{ github.head_ref }}'}".repeat(
      20,
    )
  try
    ignore(
      resolve_context(parse(source), {
        ..mr_context,
        head_ref: "x".repeat(60000),
      }),
    )
  catch {
    InvalidWorkflow(message) => assert_true(message.contains("1 MiB"))
  } noraise {
    _ => fail("oversized resolved plan accepted")
  }
}
