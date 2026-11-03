///|
pub async fn merge_test_commit(
  git_dir : String,
  branch : String,
  parent : String,
  content : String,
  preserve_files~ : Bool = false,
) -> String {
  let blob = @gitops.merge_git(
      git_dir,
      ["hash-object", "-w", "--stdin"],
      input=content,
    )
    .trim()
    .to_owned()
  let entries = if preserve_files {
    @gitops.merge_git(git_dir, ["ls-tree", parent])
    .split("\n")
    .filter_map(line => {
      if line.is_empty() || line.has_suffix("\tREADME.md") {
        None
      } else {
        Some(line.to_owned())
      }
    })
    .collect()
  } else {
    []
  }
  entries.push("100644 blob \{blob}\tREADME.md")
  let tree = @gitops.merge_git(
      git_dir,
      ["mktree"],
      input=entries.join("\n") + "\n",
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
