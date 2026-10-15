///|
test "push and manual triggers accept exact branch filters and preserve serialized plans" {
  for
    trigger in [
      "push", "[push, workflow_dispatch]", "{push: {}, workflow_dispatch: null}",
    ] {
    let source = basic_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: " + trigger,
    )
    ignore(parse(source))
    assert_true(triggers(source).matches_push("feature/one"))
  }
  let source = basic_workflow.replace_all(
    old="on: workflow_dispatch",
    new="on: {push: {branches: [master, release/stable]}, workflow_dispatch: {}}",
  )
  let trigger = triggers(source)
  assert_true(trigger.dispatch)
  assert_true(trigger.matches_push("master"))
  assert_true(trigger.matches_push("release/stable"))
  assert_false(trigger.matches_push("release/other"))
  assert_false(triggers(basic_workflow).push)
  assert_true(
    triggers(
      basic_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: pull_request",
      ),
    ).pull_request,
  )
  assert_true(
    triggers(
      basic_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: {pull_request: {types: [opened, synchronize]}}",
      ),
    ).matches_pull_request("synchronize"),
  )
  assert_eq(
    ToJson::to_json(parse(source)),
    ToJson::to_json(parse(basic_workflow)),
  )
  for
    trigger in [
      "{push: {branches: ['release/**']}}", "{push: {branches: []}}", "{push: {branches: master}}",
      "{push: {tags: [v1]}}", "{push: {paths: [src]}}", "[push, push]", "{}",
    ] {
    try
      parse(
        basic_workflow.replace_all(
          old="on: workflow_dispatch",
          new="on: " + trigger,
        ),
      )
    catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("accepted unsupported trigger: " + trigger)
    }
  }
}

///|
test "pull request types default correctly and unsupported filters fail closed" {
  let trigger = triggers(
    basic_workflow.replace_all(old="workflow_dispatch", new="pull_request"),
  )
  for event in ["opened", "reopened", "synchronize"] {
    assert_true(trigger.matches_pull_request(event))
  }
  assert_false(trigger.matches_pull_request("closed"))
  for
    config in [
      "{types: []}", "{types: opened}", "{types: [opened, opened]}", "{types: [closed]}",
      "{types: [edited]}", "{branches: [master]}", "{paths: [src]}",
    ] {
    expect_invalid(
      basic_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: {pull_request: " + config + "}",
      ),
      "on.pull_request",
    )
  }
}
