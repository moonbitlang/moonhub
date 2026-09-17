///|
pub async fn with_git_test_repo(f : async (String, String) -> Unit) -> Unit {
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
