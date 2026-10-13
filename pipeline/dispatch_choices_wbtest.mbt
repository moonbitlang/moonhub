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
    assert_eq(choices.workflows[0].reason, "Manual dispatch is not enabled")
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
