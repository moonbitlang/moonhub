///|
// More than one page, with add/delete/rename anchors and byte-only Git names.
pub async fn structured_diff_fixture(git_dir : String) -> (String, String) {
  let parent = @gitops.branch_sha(git_dir, "master")
  let before = @gitops.merge_git(
      git_dir,
      ["hash-object", "-w", "--stdin"],
      input="before\n",
    )
    .trim()
    .to_owned()
  let after = @gitops.merge_git(
      git_dir,
      ["hash-object", "-w", "--stdin"],
      input="after\n",
    )
    .trim()
    .to_owned()
  let moved = @gitops.merge_git(
      git_dir,
      ["hash-object", "-w", "--stdin"],
      input="moved source\nline two\nline three\nline four\nline five\nline six\n",
    )
    .trim()
    .to_owned()
  let moved_after = @gitops.merge_git(
      git_dir,
      ["hash-object", "-w", "--stdin"],
      input="changed source\nline two\nline three\nline four\nline five\nline six\n",
    )
    .trim()
    .to_owned()
  let invalid = @gitops.merge_git(
      git_dir,
      ["hash-object", "-w", "--stdin"],
      input="invalid path source\n",
    )
    .trim()
    .to_owned()
  let old = StringBuilder()
  let new = StringBuilder()
  for i in 100..<205 {
    old.write_string("100644 blob \{before}\ta-\{i}.txt\n")
    new.write_string("100644 blob \{after}\ta-\{i}.txt\n")
  }
  old.write_string(
    "100644 blob \{before}\tz-delete.txt\n100644 blob \{moved}\tz-old.txt\n",
  )
  new.write_string(
    "100644 blob \{after}\tz-add.txt\n100644 blob \{moved_after}\tz-new.txt\n",
  )
  // mktree's C quoting builds non-UTF-8 names without a locale/filesystem API.
  old.write_string("100644 blob \{invalid}\t\"bad-\\375\"\n")
  new.write_string(
    "100644 blob \{invalid}\t\"moved-\\375\"\n100644 blob \{after}\t\"bad-\\377\"\n100644 blob \{after}\t\"bad-\\376\"\n100644 blob \{after}\t\"\\\"bad-\\\\xff\\\"\"\n",
  )
  let old_tree = @gitops.merge_git(git_dir, ["mktree"], input=old.to_string())
    .trim()
    .to_owned()
  let base = @gitops.merge_git(git_dir, [
      "commit-tree", old_tree, "-p", parent, "-m", "Paged base",
    ])
    .trim()
    .to_owned()
  let new_tree = @gitops.merge_git(git_dir, ["mktree"], input=new.to_string())
    .trim()
    .to_owned()
  let head = @gitops.merge_git(git_dir, [
      "commit-tree", new_tree, "-p", base, "-m", "Paged head",
    ])
    .trim()
    .to_owned()
  ignore(
    @gitops.merge_git(git_dir, ["update-ref", "refs/heads/paged-base", base]),
  )
  ignore(
    @gitops.merge_git(git_dir, ["update-ref", "refs/heads/paged-head", head]),
  )
  (base, head)
}
