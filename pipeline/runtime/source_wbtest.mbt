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
