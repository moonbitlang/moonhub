///|
async test "list repository fixtures" {
  @test_support.with_git_test_repo(async fn(root, git_dir) {
    let repos = list_repositories(root)
    assert_eq(repos.length(), 1)
    assert_eq(repos[0].path(), "alice/demo")
    @fs.mkdir("\{root}/dii")
    @fs.symlink(target=git_dir, "\{root}/dii/ideas.git")
    let repos = list_repositories(root)
    assert_eq(repos.length(), 2)
    let paths = repos.map(repo => repo.path())
    assert_true(paths.contains("alice/demo"))
    assert_true(paths.contains("dii/ideas"))
  })
}

///|
async test "browse repository fixture" {
  let git_dir = "testdata/repos/alice/demo.git"
  let entries = list_tree(git_dir, "master", "")
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].name, "src")
  assert_eq(entries[0].kind, "tree")
  assert_eq(entries[1].name, "README.md")
  assert_eq(entries[1].kind, "blob")
  assert_eq(
    read_blob(git_dir, "master", "README.md"),
    "hello fixture moonhub\n",
  )
  let commits = list_commits(git_dir, "master")
  assert_eq(commits.length(), 1)
  assert_eq(commits[0].subject, "initial fixture commit")
  assert_eq(commits[0].author, "Test")
  assert_eq(commits[0].date, "2024-01-02")
}

///|
async test "automatic browsing falls back without mutating a missing default branch" {
  @test_support.with_git_test_repo((_, git_dir) => {
    ignore(run_git(git_dir, ["symbolic-ref", "HEAD", "refs/heads/missing"]))
    assert_eq(default_ref(git_dir), "missing")
    assert_eq(resolve_ref(git_dir, None), "master")
    ignore(run_git(git_dir, ["update-ref", "refs/heads/main", "master"]))
    assert_eq(resolve_ref(git_dir, None), "main")
    ignore(run_git(git_dir, ["update-ref", "refs/heads/selfhost", "master"]))
    ignore(run_git(git_dir, ["symbolic-ref", "HEAD", "refs/heads/selfhost"]))
    assert_eq(resolve_ref(git_dir, None), "selfhost")
    ignore(run_git(git_dir, ["update-ref", "-d", "refs/heads/selfhost"]))
    assert_eq(resolve_ref(git_dir, None), "main")
    assert_eq(default_ref(git_dir), "selfhost")
    assert_eq(resolve_ref(git_dir, Some("missing")), "missing")
  })
}

///|
async test "fallback handles slash branches ambiguous tags and detached HEAD" {
  @test_support.with_git_test_repo((_, git_dir) => {
    let sha = run_git(git_dir, ["rev-parse", "master"]).trim().to_owned()
    ignore(run_git(git_dir, ["update-ref", "refs/heads/z-last", sha]))
    ignore(run_git(git_dir, ["update-ref", "refs/heads/feature/first", sha]))
    ignore(run_git(git_dir, ["update-ref", "-d", "refs/heads/master"]))
    assert_eq(resolve_ref(git_dir, None), "feature/first")
    let blob = run_git(git_dir, ["rev-parse", sha + ":README.md"])
      .trim()
      .to_owned()
    ignore(run_git(git_dir, ["update-ref", "refs/tags/feature/first", blob]))
    assert_eq(resolve_ref(git_dir, None), sha)
    ignore(
      run_git(git_dir, ["symbolic-ref", "HEAD", "refs/heads/feature/first"]),
    )
    assert_eq(resolve_ref(git_dir, None), sha)
    ignore(run_git(git_dir, ["update-ref", "refs/tags/HEAD", blob]))
    assert_eq(resolve_ref(git_dir, None), sha)
    ignore(run_git(git_dir, ["update-ref", "--no-deref", "HEAD", sha]))
    assert_eq(resolve_ref(git_dir, None), "HEAD")
  })
}

///|
async test "tag-only repositories remain browsable but private retention refs are not defaults" {
  @test_support.with_git_test_repo((_, git_dir) => {
    let sha = run_git(git_dir, ["rev-parse", "master"]).trim().to_owned()
    let blob = run_git(git_dir, ["rev-parse", "master:README.md"])
      .trim()
      .to_owned()
    let tag = @gitops.merge_git(
        git_dir,
        ["mktag"],
        input="object \{sha}\ntype commit\ntag release/v1\ntagger Test <test@example.invalid> 1704153600 +0000\n\nRelease\n",
      )
      .trim()
      .to_owned()
    ignore(run_git(git_dir, ["update-ref", "refs/tags/00-blob", blob]))
    ignore(run_git(git_dir, ["update-ref", "refs/tags/release/v1", tag]))
    ignore(
      run_git(git_dir, ["update-ref", "refs/moonhub/pipelines/private", sha]),
    )
    ignore(run_git(git_dir, ["update-ref", "-d", "refs/heads/master"]))
    assert_eq(resolve_ref(git_dir, None), "release/v1")
    assert_eq(list_commits(git_dir, resolve_ref(git_dir, None)).length(), 1)
    ignore(run_git(git_dir, ["update-ref", "-d", "refs/tags/release/v1"]))
    ignore(run_git(git_dir, ["update-ref", "-d", "refs/tags/00-blob"]))
    assert_eq(resolve_ref(git_dir, None), "master")
    assert_true(is_unborn_default_ref(git_dir, "master"))
  })
}

///|
async test "default fallback does not hide invalid repository errors" {
  @test_support.with_git_test_repo((root, _) => {
    try ignore(resolve_ref(root + "/missing.git", None)) catch {
      GitCommandFailed(code=128, ..) => ()
      err => raise err
    } noraise {
      _ => fail("invalid repository was treated as an empty repository")
    }
  })
}

///|
async test "git command failures raise" {
  try
    read_blob("testdata/repos/alice/demo.git", "master", "missing.mbt")
  catch {
    GitCommandFailed(code~, output~) => {
      assert_eq(code, 128)
      assert_true(output.contains("missing.mbt"))
    }
    err => raise err
  } noraise {
    _ => fail("expected missing blob to raise")
  }
}

///|
test "tree metadata preserves space-padded sizes and filenames" {
  let file = parse_tree_entry(
    "100644 blob abc123      24\tfile with spaces.mbt",
  ).unwrap()
  assert_eq(file.size, Some("24"))
  assert_eq(file.name, "file with spaces.mbt")
  let directory = parse_tree_entry("040000 tree abc123       -\tsrc").unwrap()
  assert_true(directory.size is None)
  assert_eq(directory.kind, "tree")
}

///|
async test "trees group directories first and sort names within each group" {
  @test_support.with_git_test_repo((_, git_dir) => {
    let blob = run_git(git_dir, ["rev-parse", "master:README.md"])
      .trim()
      .to_owned()
    let subtree = run_git(git_dir, ["rev-parse", "master^{tree}"])
      .trim()
      .to_owned()
    let tree = @gitops.merge_git(
        git_dir,
        ["mktree"],
        input="100644 blob \{blob}\tz.txt\n040000 tree \{subtree}\tz-dir\n100644 blob \{blob}\tA-long-file.md\n040000 tree \{subtree}\talpha-dir\n",
      )
      .trim()
      .to_owned()
    assert_eq(list_tree(git_dir, tree, "").map(entry => entry.name), [
      "alpha-dir", "z-dir", "A-long-file.md", "z.txt",
    ])
    assert_eq(list_tree(git_dir, tree, "alpha-dir").map(entry => entry.name), [
      "src", "README.md",
    ])
  })
}
