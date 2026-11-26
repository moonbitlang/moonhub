///|
test "tar rejects symlinks and submodules while both formats reject unsafe paths" {
  let hash = "a".repeat(40)
  validate_source_tree(
    "100644 blob \{hash}\tREADME.md\u{0000}100755 blob \{hash}\tbin/build\u{0000}",
  )
  validate_source_tree(
    "120000 blob \{hash}\tlink\u{0000}160000 commit \{hash}\tsrc/parser\u{0000}",
    git_bundle=true,
  )
  for
    entry in [
      "120000 blob \{hash}\tlink",
      "160000 commit \{hash}\tmodule",
      "100644 blob \{hash}\t.home/.moon/config",
      "100644 blob \{hash}\t.tmp/file",
      "100644 blob \{hash}\t.git/config",
      "120000 blob \{hash}\t.git/config",
      "160000 commit \{hash}\t.home/module",
      "160000 commit \{hash}\t.tmp/module",
      "160000 commit \{hash}\tsrc/.git/module",
      "160000 commit \{hash}\t../module",
      "160000 commit \{hash}\t/absolute-module",
      "160000 commit \{hash}\tsrc\\module",
      "160000 commit \{hash}\tsrc\nmodule",
      "040000 tree \{hash}\tdirectory",
      "160000 blob \{hash}\twrong-type",
      "100644 blob \{hash}\t../outside",
      "100644 blob \{hash}\t/absolute",
      "100644 blob \{hash}\ta\nfile",
    ] {
    try validate_source_tree(entry + "\u{0000}") catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("unsafe checkout tree accepted")
    }
    if entry != "120000 blob \{hash}\tlink" &&
      entry != "160000 commit \{hash}\tmodule" {
      try validate_source_tree(entry + "\u{0000}", git_bundle=true) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("unsafe bundle tree accepted")
      }
    }
  }
}

///|
async test "full source history budget includes annotated tags" {
  let root = @fs.tmpdir(prefix="moonhub-history-budget-")
  defer @fs.rmdir(root, recursive=true)
  let repo : @domain.RepoId = { owner: "alice", name: "source", }
  @fs.mkdir(root + "/alice")
  let dir = repo.git_dir(root)
  assert_eq(@process.run("git", ["init", "--bare", "--quiet", dir]), 0)
  let tree = @gitops.merge_git(dir, ["mktree"]).trim().to_owned()
  let sha = @gitops.merge_git(dir, ["commit-tree", tree, "-m", "source"])
    .trim()
    .to_owned()
  ignore(
    source_bundle(
      root,
      repo,
      sha,
      full_history=true,
      expanded_history_limit=1024L,
    ),
  )
  ignore(
    @gitops.merge_git(dir, [
      "tag",
      "-a",
      "v1",
      sha,
      "-m",
      "tag body ".repeat(256),
    ]),
  )
  try
    ignore(
      source_bundle(
        root,
        repo,
        sha,
        full_history=true,
        expanded_history_limit=1024L,
      ),
    )
  catch {
    @domain.BadRequest(message~) =>
      assert_true(message.contains("expanded object budget"))
    err => raise err
  } noraise {
    _ => fail("annotated tag omitted from the expanded history budget")
  }
}
