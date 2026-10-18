///|
test "anchor context selects one side within one visible hunk" {
  let patch = "diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1,3 +1,4 @@\n context\n-old\n+new\n+added\n tail\n"
  assert_eq(
    anchor_context(patch, "old", 1L, 3L),
    "1: context\n2: old\n3: tail\n",
  )
  assert_eq(anchor_context(patch, "new", 2L, 3L), "2: new\n3: added\n")
  for side in ["old", "new"] {
    try ignore(anchor_context(patch, side, 4L, 5L)) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted missing lines")
    }
  }
  try
    ignore(
      anchor_context(patch + "@@ -4,1 +5,1 @@\n-last\n+next\n", "old", 3L, 4L),
    )
  catch {
    @domain.BadRequest(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted cross-hunk range")
  }
}

///|
async test "anchors bind full or per-commit comparisons and reject nonexistent diff positions" {
  @test_support.with_repository_test_data((_pool, root) => {
    let dir = "\{root}/alice/demo.git"
    let base = branch_sha(dir, "master")
    let first = @test_support.merge_test_commit(
      dir, "feature", base, "one\ntwo\nthree\n",
    )
    let second = @test_support.merge_test_commit(
      dir, "feature", first, "inserted\none\nchanged\nthree\n",
    )
    let revision = compare_branches(dir, "feature", "master")
    let anchor = validate_diff_anchor(
      dir,
      revision,
      None,
      "README.md",
      "new",
      2L,
      3L,
    )
    assert_eq(anchor.base_sha, base)
    assert_eq(anchor.head_sha, second)
    assert_eq(anchor.context, "2: one\n3: changed\n")
    let anchor = validate_diff_anchor(
      dir,
      revision,
      Some(second),
      "README.md",
      "old",
      2L,
      2L,
    )
    assert_eq(anchor.base_sha, first)
    assert_eq(anchor.context, "2: two\n")
    for
      (path, side, start, end) in [
        ("missing", "new", 1L, 1L),
        ("README.md", "old", 99L, 99L),
        ("README.md", "new", 2L, 1L),
        ("README.md", "other", 1L, 1L),
        ("README.md", "new", 1L, 101L),
      ] {
      try
        ignore(
          validate_diff_anchor(dir, revision, None, path, side, start, end),
        )
      catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid anchor")
      }
    }
    let blob = merge_git(
        dir,
        ["hash-object", "-w", "--stdin"],
        input="inserted\none\nchanged\nthree\n",
      )
      .trim()
      .to_owned()
    let tree = merge_git(
        dir,
        ["mktree"],
        input="100644 blob \{blob}\tfile with space.txt\n",
      )
      .trim()
      .to_owned()
    let renamed = merge_git(dir, [
        "commit-tree", tree, "-p", second, "-m", "Rename",
      ])
      .trim()
      .to_owned()
    ignore(merge_git(dir, ["update-ref", "refs/heads/feature", renamed]))
    let current = compare_branches(dir, "feature", "master")
    // A pure rename has no displayed hunk and cannot accept fabricated line anchors.
    try
      ignore(
        validate_diff_anchor(
          dir,
          current,
          Some(renamed),
          "file with space.txt",
          "new",
          1L,
          1L,
        ),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted pure rename position")
    }
    assert_eq(
      validate_diff_anchor(
        dir,
        revision,
        Some(second),
        "README.md",
        "new",
        3L,
        3L,
      ).head_sha,
      second,
    )
  })
}

///|
async test "anchors retain exact paths across additions deletions and modified renames" {
  @test_support.with_repository_test_data((_pool, root) => {
    let dir = "\{root}/alice/demo.git"
    let original = branch_sha(dir, "master")
    let contents = "first\nsecond\nthird\nfourth\nfifth\n"
    let blob = merge_git(dir, ["hash-object", "-w", "--stdin"], input=contents)
      .trim()
      .to_owned()
    let tree = merge_git(
        dir,
        ["mktree", "-z"],
        input="100644 blob \{blob}\told name.txt\u{0000}100644 blob \{blob}\tdeleted.txt\u{0000}",
      )
      .trim()
      .to_owned()
    let base = merge_git(dir, [
        "commit-tree", tree, "-p", original, "-m", "Prepare files",
      ])
      .trim()
      .to_owned()
    let changed = merge_git(
        dir,
        ["hash-object", "-w", "--stdin"],
        input="first\nchanged\nthird\nfourth\nfifth\n",
      )
      .trim()
      .to_owned()
    let tree = merge_git(
        dir,
        ["mktree", "-z"],
        input="100644 blob \{changed}\t新 name.txt\u{0000}100644 blob \{changed}\tadded.txt\u{0000}",
      )
      .trim()
      .to_owned()
    let head = merge_git(dir, [
        "commit-tree", tree, "-p", base, "-m", "Rename add delete",
      ])
      .trim()
      .to_owned()
    ignore(merge_git(dir, ["update-ref", "refs/heads/feature", head]))
    let revision = compare_branches(dir, "feature", "master")
    let renamed = validate_diff_anchor(
      dir,
      revision,
      Some(head),
      "新 name.txt",
      "new",
      2L,
      2L,
    )
    assert_eq(renamed.new_path, "新 name.txt")
    assert_eq(renamed.context, "2: changed\n")
    let deleted = validate_diff_anchor(
      dir,
      revision,
      Some(head),
      "deleted.txt",
      "old",
      1L,
      2L,
    )
    assert_eq(deleted.context, "1: first\n2: second\n")
    let added = validate_diff_anchor(
      dir,
      revision,
      Some(head),
      "added.txt",
      "new",
      1L,
      2L,
    )
    assert_eq(added.context, "1: first\n2: changed\n")
    // Git may pair either identical original as the rename source; both sides still map correctly.
    let old = validate_diff_anchor(
      dir,
      revision,
      Some(head),
      renamed.old_path,
      "old",
      2L,
      2L,
    )
    assert_eq(old.context, "2: second\n")
    assert_eq(old.new_path, renamed.new_path)
  })
}
