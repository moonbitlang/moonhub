///|
async fn with_git_test_repo(f : async (String, String) -> Unit) -> Unit {
  let root = @fs.tmpdir(prefix="moonhub-git-")
  defer @fs.rmdir(root, recursive=true)
  @fs.mkdir("\{root}/alice")
  let source = @fs.realpath("testdata/repos/alice/demo.git")
  let git_dir = "\{root}/alice/demo.git"
  let (code, output) = @process.collect_output_merged("git", [
    "clone", "--bare", "--no-hardlinks", "--quiet", source, git_dir,
  ])
  assert_eq(code, 0, msg=output.text())
  f(root, git_dir)
}

///|
async test "list repository fixtures" {
  with_git_test_repo(async fn(root, git_dir) {
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
  with_git_test_repo((_, git_dir) => {
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
