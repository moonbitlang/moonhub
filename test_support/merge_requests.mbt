///|
pub async fn merge_test_commit(
  git_dir : String,
  branch : String,
  parent : String,
  content : String,
) -> String {
  let blob = @gitops.merge_git(
      git_dir,
      ["hash-object", "-w", "--stdin"],
      input=content,
    )
    .trim()
    .to_owned()
  let tree = @gitops.merge_git(
      git_dir,
      ["mktree"],
      input="100644 blob \{blob}\tREADME.md\n",
    )
    .trim()
    .to_owned()
  let commit = @gitops.merge_git(git_dir, [
      "commit-tree",
      tree,
      "-p",
      parent,
      "-m",
      "Update \{branch}: \{content}",
    ])
    .trim()
    .to_owned()
  ignore(
    @gitops.merge_git(git_dir, ["update-ref", "refs/heads/\{branch}", commit]),
  )
  commit
}
