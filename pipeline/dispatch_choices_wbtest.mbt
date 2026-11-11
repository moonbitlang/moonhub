///|
async test "manual workflow choices use real branches and validate workflow dispatch" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let sha = @test_support.workflow_commit(repo.git_dir(root), sample_workflow)
    let choices = dispatch_choices(pool, root, actor, repo, "pipeline")
    assert_eq(choices.commit, sha)
    assert_eq(choices.workflows.length(), 1)
    assert_eq(choices.workflows[0].path, ".github/workflows/build.yml")
    assert_eq(choices.workflows[0].reason, "")
    ignore(
      @test_support.workflow_commit(
        repo.git_dir(root),
        sample_workflow.replace_all(old="workflow_dispatch", new="push"),
      ),
    )
    let choices = dispatch_choices(pool, root, actor, repo, "pipeline")
    assert_eq(choices.workflows[0].reason, "")
    assert_false(choices.workflows[0].dispatch)
    assert_eq(choices.workflows[0].jobs, ["build", "test"])
    ignore(
      @gitops.merge_git(repo.git_dir(root), [
        "symbolic-ref", "HEAD", "refs/heads/absent",
      ]),
    )
    let choices = dispatch_choices(pool, root, actor, repo, "")
    assert_true(choices.branches.contains(choices.branch))
    assert_true(choices.branch != "absent")
  })
}

///|
async test "manual workflow choices expose input definitions from the selected revision" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let git_dir = repo.git_dir(root)
    let source = sample_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on:\n  workflow_dispatch:\n    inputs:\n      version: {description: Release version, type: string, required: true}\n      publish: {type: boolean, default: false}\n      count: {type: number, default: 2.5}\n      channel: {type: choice, options: [stable, beta], default: stable}",
    )
    let old_commit = @test_support.workflow_commit(git_dir, source)
    ignore(
      @gitops.merge_git(git_dir, [
        "update-ref", "refs/heads/dispatch-inputs", old_commit,
      ]),
    )
    let choice = dispatch_choices(pool, root, actor, repo, "pipeline").workflows[0]
    assert_eq(choice.name, "Build")
    assert_eq(choice.reason, "")
    assert_eq(choice.inputs.length(), 4)
    let version = choice.inputs
      .iter()
      .find_first(input => input.name == "version")
      .unwrap()
    assert_eq(version.description, "Release version")
    assert_eq(version.kind, "string")
    assert_true(version.required)
    assert_eq(version.default, None)
    assert_eq(
      choice.inputs.iter().find_first(input => input.name == "publish").unwrap().default,
      Some(Json(false)),
    )
    assert_eq(
      choice.inputs.iter().find_first(input => input.name == "count").unwrap().default,
      Some(Json(2.5)),
    )
    let channel = choice.inputs
      .iter()
      .find_first(input => input.name == "channel")
      .unwrap()
    assert_eq(channel.options, ["stable", "beta"])
    assert_eq(channel.default, Some(Json("stable")))
    ignore(@test_support.workflow_commit(git_dir, sample_workflow))
    assert_true(
      dispatch_choices(pool, root, actor, repo, "pipeline").workflows[0].inputs.is_empty(),
    )
    assert_eq(
      dispatch_choices(pool, root, actor, repo, "dispatch-inputs").workflows[0].inputs.length(),
      4,
    )
    ignore(
      @test_support.workflow_commit(
        git_dir,
        source.replace_all(old="type: number", new="type: environment"),
      ),
    )
    let invalid = dispatch_choices(pool, root, actor, repo, "pipeline").workflows[0]
    assert_eq(invalid.reason, "environment dispatch inputs are not supported")
    assert_true(invalid.inputs.is_empty())
  })
}
