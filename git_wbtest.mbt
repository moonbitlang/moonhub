///|
async test "list repository fixtures" {
  let repos = list_repositories("testdata/repos")
  assert_eq(repos.length(), 1)
  assert_eq(repos[0].path(), "alice/demo")
}

///|
async test "browse repository fixture" {
  let git_dir = "testdata/repos/alice/demo.git"
  let entries = list_tree(git_dir, "master", "")
  assert_eq(entries.length(), 2)
  assert_eq(entries[0].name, "README.md")
  assert_eq(entries[0].kind, "blob")
  assert_eq(entries[1].name, "src")
  assert_eq(entries[1].kind, "tree")
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
