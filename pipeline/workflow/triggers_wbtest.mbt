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
      "{push: {branches: []}}", "{push: {branches: master}}", "[push, push]", "{}",
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
  for config in ["{types: []}", "{types: opened}", "{types: [opened, opened]}"] {
    expect_invalid(
      basic_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: {pull_request: " + config + "}",
      ),
      "on.pull_request",
    )
  }
}

///|
test "stable release triggers can coexist with workflow dispatch" {
  for trigger in ["release", "[release, push]", "{release: {}}"] {
    let source = basic_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: " + trigger,
    )
    ignore(parse(source))
    assert_true(triggers(source).release)
    assert_false(triggers(source).dispatch)
  }
  let source = basic_workflow.replace_all(
    old="on: workflow_dispatch",
    new="on:\n  release:\n    types:\n      - released\n  workflow_dispatch:",
  )
  ignore(parse(source))
  assert_true(triggers(source).release)
  assert_true(triggers(source).dispatch)
  assert_false(triggers(basic_workflow).release)
  for
    config in [
      "{types: []}", "{types: released}", "{types: [released, prereleased]}", "{types: [released, released]}",
      "{branches: [master]}",
    ] {
    expect_invalid(
      basic_workflow.replace_all(
        old="on: workflow_dispatch",
        new="on: {release: " + config + ", workflow_dispatch: null}",
      ),
      "on.release",
    )
  }
}

///|
test "tag push filters release publication and lifecycle types retain default subscriptions" {
  let tag = triggers(
    basic_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {push: {tags: ['v*', '!v*-beta*'], paths: ['src/**']}}",
    ),
  )
  assert_true(tag.matches_push("v1", tag=true, paths=Some([])))
  assert_false(tag.matches_push("v1-beta1", tag=true))
  assert_false(tag.matches_push("master"))
  let branch = triggers(
    basic_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {push: {branches: [master]}}",
    ),
  )
  assert_false(branch.matches_push("v1", tag=true))
  let events = triggers(
    basic_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {release: {types: [published, released]}, repository_dispatch: {types: [deploy]}, workflow_run: {workflows: [Build], types: [completed], branches: [master]}, pull_request: {types: [closed, edited, ready_for_review]}}",
    ),
  )
  assert_true(events.matches_pull_request("closed"))
  assert_false(events.matches_pull_request("opened"))
  assert_true(events.matches_repository_dispatch("deploy"))
  assert_false(events.matches_repository_dispatch("other"))
  assert_true(events.matches_workflow_run("Build", "master"))
  assert_false(events.matches_workflow_run("Build", "feature"))
  assert_false(events.matches_workflow_run("Other", "master"))
}
