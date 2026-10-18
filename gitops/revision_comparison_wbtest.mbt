///|
async test "revision comparison scopes commits to immutable MR ranges and compares first parent" {
  @test_support.with_repository_test_data((_pool, root) => {
    let git_dir = "\{root}/alice/demo.git"
    let base = branch_sha(git_dir, "master")
    let first = @test_support.merge_test_commit(
      git_dir, "feature", base, "one\n",
    )
    let second = @test_support.merge_test_commit(
      git_dir, "feature", first, "two\n",
    )
    let revision = compare_branches(git_dir, "feature", "master")
    let all = revision_comparison(git_dir, revision, None)
    assert_eq(all.base_sha, base)
    assert_eq(all.head_sha, second)
    assert_true(all.commit is None)
    let selected = revision_comparison(git_dir, revision, Some(second))
    assert_eq(selected.base_sha, first)
    assert_eq(selected.head_sha, second)
    assert_eq(selected.parent_count, 1)
    assert_true(selected.commit is Some({ hash, .. }) && hash == second)
    let patch = merge_git(git_dir, [
      "diff",
      selected.base_sha,
      selected.head_sha,
      "--",
    ])
    assert_true(patch.contains("-one\n+two"))
    let commits = revision_commits(git_dir, revision, 1L)
    assert_eq(commits.length(), 2)
    assert_eq(commits[0].hash, second)
    assert_eq(commits[1].hash, first)
    assert_true(revision_commits(git_dir, revision, 2L).is_empty())
    let outsider = @test_support.merge_test_commit(
      git_dir, "other", base, "other\n",
    )
    let tag = merge_git(
        git_dir,
        ["mktag"],
        input="object \{second}\ntype commit\ntag review-tag\ntagger Fixture <fixture@example.invalid> 1704153600 +0000\n\nTag note\n",
      )
      .trim()
      .to_owned()
    let tree_id = merge_git(git_dir, ["rev-parse", "\{second}^{tree}"])
      .trim()
      .to_owned()
    let blob_id = merge_git(git_dir, ["rev-parse", "\{second}:README.md"])
      .trim()
      .to_owned()
    for
      invalid in [
        base, outsider, tag, tree_id, blob_id, "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      ] {
      try ignore(revision_comparison(git_dir, revision, Some(invalid))) catch {
        @domain.NotFound(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted commit outside MR range")
      }
    }
    for invalid in ["HEAD", "--stat", second[:12].to_owned(), second.to_upper()] {
      try ignore(revision_comparison(git_dir, revision, Some(invalid))) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted malformed SHA")
      }
    }
    for page in [0L, 100001L] {
      try ignore(revision_commits(git_dir, revision, page)) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid commit page")
      }
    }
    let tree = merge_git(git_dir, ["rev-parse", "\{second}^{tree}"])
      .trim()
      .to_owned()
    let merged = merge_git(git_dir, [
        "commit-tree", tree, "-p", second, "-p", outsider, "-m", "Merge other",
      ])
      .trim()
      .to_owned()
    ignore(merge_git(git_dir, ["update-ref", "refs/heads/feature", merged]))
    let current = compare_branches(git_dir, "feature", "master")
    let selected = revision_comparison(git_dir, current, Some(merged))
    assert_eq(selected.parent_count, 2)
    assert_eq(selected.base_sha, second)
    assert_eq(selected.head_sha, merged)
    assert_eq(
      revision_comparison(git_dir, current, Some(outsider)).base_sha,
      base,
    )
    try ignore(revision_comparison(git_dir, revision, Some(merged))) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("new commit leaked into historical revision")
    }
    let root_commit = merge_git(git_dir, [
        "commit-tree", tree, "-m", "Imported root",
      ])
      .trim()
      .to_owned()
    let combined = merge_git(git_dir, [
        "commit-tree", tree, "-p", merged, "-p", root_commit, "-m", "Import history",
      ])
      .trim()
      .to_owned()
    ignore(merge_git(git_dir, ["update-ref", "refs/heads/feature", combined]))
    let combined_revision = compare_branches(git_dir, "feature", "master")
    let selected = revision_comparison(
      git_dir,
      combined_revision,
      Some(root_commit),
    )
    assert_eq(selected.parent_count, 0)
    assert_true(
      merge_git(git_dir, ["diff", selected.base_sha, selected.head_sha, "--"]).contains(
        "+two",
      ),
    )
    // Rewrite the branch and advance target: saved revisions still compare their original objects.
    ignore(merge_git(git_dir, ["update-ref", "refs/heads/feature", outsider]))
    ignore(merge_git(git_dir, ["update-ref", "refs/heads/master", merged]))
    assert_eq(
      revision_comparison(git_dir, revision, Some(second)).base_sha,
      first,
    )
  })
}

///|
async test "revision commit pagination keeps commits beyond the first hundred selectable" {
  @test_support.with_repository_test_data((_pool, root) => {
    let git_dir = "\{root}/alice/demo.git"
    let base = branch_sha(git_dir, "master")
    let mut head = base
    let tree = merge_git(git_dir, ["rev-parse", "\{base}^{tree}"])
      .trim()
      .to_owned()
    let mut oldest = ""
    for i = 0; i < 102; i = i + 1 {
      head = merge_git(git_dir, [
          "commit-tree",
          tree,
          "-p",
          head,
          "-m",
          "Commit \{i}",
        ])
        .trim()
        .to_owned()
      if i == 0 {
        oldest = head
      }
    }
    ignore(merge_git(git_dir, ["update-ref", "refs/heads/many", head]))
    let revision = compare_branches(git_dir, "many", "master")
    let first = revision_commits(git_dir, revision, 1L)
    let second = revision_commits(git_dir, revision, 2L)
    assert_eq(first.length(), 101)
    assert_eq(second.length(), 2)
    assert_eq(first[100].hash, second[0].hash)
    assert_eq(second[1].hash, oldest)
    assert_eq(
      revision_comparison(git_dir, revision, Some(oldest)).base_sha,
      base,
    )
  })
}

///|
async test "commit metadata previews drain long fields without corrupting framing or UTF-8" {
  @test_support.with_repository_test_data((_pool, root) => {
    let git_dir = "\{root}/alice/demo.git"
    let base = branch_sha(git_dir, "master")
    let tree = merge_git(git_dir, ["rev-parse", "\{base}^{tree}"])
      .trim()
      .to_owned()
    let long_subject = "x".repeat(2047) + "中".repeat(9000)
    let author = "文".repeat(9000)
    let raw = "tree \{tree}\nparent \{base}\nauthor \{author} <fixture@example.invalid> 1704153600 +0000\ncommitter Fixture <fixture@example.invalid> 1704153600 +0000\n\n\{long_subject}\n"
    let commit = merge_git(
        git_dir,
        ["hash-object", "-t", "commit", "-w", "--stdin"],
        input=raw,
      )
      .trim()
      .to_owned()
    ignore(merge_git(git_dir, ["update-ref", "refs/heads/long", commit]))
    let revision = compare_branches(git_dir, "long", "master")
    let listed = revision_commits(git_dir, revision, 1L)
    assert_eq(listed.length(), 1)
    assert_eq(listed[0].hash, commit)
    assert_eq(listed[0].subject, "x".repeat(2047) + "…")
    assert_eq(listed[0].author, "文".repeat(170) + "…")
    assert_true(!listed[0].subject.contains("\u{fffd}"))
    assert_true(!listed[0].author.contains("\u{fffd}"))
    let selected = revision_comparison(git_dir, revision, Some(commit))
    assert_true(
      selected.commit is Some(info) &&
      info.hash == commit &&
      info.subject == listed[0].subject &&
      info.author == listed[0].author,
    )
    assert_eq(
      merge_git(git_dir, ["show", "-s", "--format=%s", commit])
      .trim()
      .to_owned(),
      long_subject,
    )
    let separators = merge_git(
        git_dir,
        ["commit-tree", tree, "-p", commit],
        input="Contains\u{1f}delimiter\n",
      )
      .trim()
      .to_owned()
    ignore(merge_git(git_dir, ["update-ref", "refs/heads/long", separators]))
    let current = compare_branches(git_dir, "long", "master")
    assert_true(
      revision_comparison(git_dir, current, Some(separators)).commit
      is Some(info) &&
      info.hash == separators &&
      info.subject == "Contains\u{1f}delimiter",
    )
  })
}
