///|
async test "code navigation bounds paths and distinguishes a branch from its same-named tag" {
  @test_support.with_git_test_repo((_, dir) => {
    let original = @gitops.run_git(dir, ["rev-parse", "master"])
      .trim()
      .to_owned()
    let blob = @gitops.run_git(dir, ["rev-parse", "master:README.md"])
      .trim()
      .to_owned()
    let input = StringBuilder()
    for i in 0..<5002 {
      input.write_string("100644 blob \{blob}\tfile-\{i}.md\u{0}")
    }
    let tree = @gitops.merge_git(dir, ["mktree", "-z"], input=input.to_string())
      .trim()
      .to_owned()
    let head = @gitops.merge_git(dir, [
        "commit-tree", tree, "-p", original, "-m", "Many files",
      ])
      .trim()
      .to_owned()
    ignore(
      @gitops.run_git(dir, ["update-ref", "refs/heads/feature/files", head]),
    )
    ignore(
      @gitops.run_git(dir, ["update-ref", "refs/tags/feature/files", original]),
    )
    // Reference enumeration must not drop tags after a large set of branches:
    // otherwise a same-named tag could shadow a supposedly selected branch.
    let references = StringBuilder()
    for i in 0..<5001 {
      references.write_string("create refs/heads/bounded/\{i} \{original}\n")
    }
    ignore(
      @gitops.merge_git(
        dir,
        ["update-ref", "--stdin"],
        input=references.to_string(),
      ),
    )
    let navigation = code_navigation(dir, head)
    assert_eq(navigation.paths.length(), 5000)
    assert_true(navigation.truncated)
    assert_true(navigation.refs.contains((head, "Branch: feature/files")))
    assert_true(navigation.refs.contains((original, "Tag: feature/files")))
    let small = code_navigation(dir, original)
    assert_true(!small.truncated)
    assert_true(small.paths.contains("README.md"))
  })
}
