///|
async test "MR Changes selects a commit in context and preserves historical revision scope" {
  @web_testkit.with_repository_test_app((
    port,
    pool,
    root,
    alice_cookie,
    bob_cookie,
  ) => {
    let git_dir = "\{root}/alice/demo.git"
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let base = @gitops.branch_sha(git_dir, "master")
    let first = @test_support.merge_test_commit(
      git_dir, "feature", base, "one\n",
    )
    let second = @test_support.merge_test_commit(
      git_dir, "feature", first, "two\n",
    )
    ignore(
      @collaboration.create_merge_request(
        pool, scope, git_dir, alice, "Commit review", "", "feature", "master", false,
      ),
    )
    let url = "/alice/demo/merge-requests/1"
    let (status, html) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=changes&version=1",
      alice_cookie,
    )
    assert_eq(status.code, 200)
    assert_true(html.contains("All changes in v1"))
    assert_true(html.contains("id=\"mr-commit\""))
    assert_true(html.contains("+two"))
    let (status, selected) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=changes&version=1&commit=" + second,
      alice_cookie,
    )
    assert_eq(status.code, 200)
    assert_true(selected.contains("-one\n+two"))
    assert_true(selected.contains("Compared with parent"))
    assert_true(selected.contains("Reviews apply to the entire MR version."))
    assert_true(selected.contains("name=\"version\" value=\"1\""))
    assert_true(selected.contains("Commit details</a>"))
    assert_true(selected.contains("Review and merge readiness"))
    let (_, commits) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=commits&version=1",
      alice_cookie,
    )
    assert_true(
      commits.contains("?tab=changes&amp;version=1&amp;commit=" + second),
    )
    let tag = @gitops.merge_git(
        git_dir,
        ["mktag"],
        input="object \{second}\ntype commit\ntag review-tag\ntagger Fixture <fixture@example.invalid> 1704153600 +0000\n\nTag note\n",
      )
      .trim()
      .to_owned()
    let (status, _) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=changes&version=1&commit=" + tag,
      alice_cookie,
    )
    assert_eq(status.code, 404)
    let third = @test_support.merge_test_commit(
      git_dir, "feature", second, "three\n",
    )
    let (status, old) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=changes&version=1&commit=" + second,
      alice_cookie,
    )
    assert_eq(status.code, 200)
    assert_true(old.contains("Viewing an older version"))
    assert_true(old.contains("-one\n+two"))
    for
      query in [
        "?tab=changes&version=1&commit=" + third,
        "?tab=changes&version=2&commit=" + base,
      ] {
      let (status, _) = @web_testkit.http_get_path_with_cookie(
        port,
        url + query,
        alice_cookie,
      )
      assert_eq(status.code, 404)
    }
    for
      query in [
        "?tab=changes&commit=HEAD",
        "?tab=changes&commit_page=100001",
        "?tab=commits&commit=" + second,
      ] {
      let (status, _) = @web_testkit.http_get_path_with_cookie(
        port,
        url + query,
        alice_cookie,
      )
      assert_eq(status.code, 400)
    }
    let (status, _) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=changes&commit=" + second,
      bob_cookie,
    )
    assert_eq(status.code, 404)
    let tree = @gitops.merge_git(git_dir, ["rev-parse", "\{third}^{tree}"])
      .trim()
      .to_owned()
    let side = @test_support.merge_test_commit(git_dir, "side", base, "side\n")
    let merge = @gitops.merge_git(git_dir, [
        "commit-tree", tree, "-p", third, "-p", side, "-m", "Merge side",
      ])
      .trim()
      .to_owned()
    ignore(
      @gitops.merge_git(git_dir, ["update-ref", "refs/heads/feature", merge]),
    )
    let (status, html) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "?tab=changes&commit=" + merge,
      alice_cookie,
    )
    assert_eq(status.code, 200)
    assert_true(html.contains("Merge commit compared with first parent"))
    assert_true(html.contains("No file changes in this comparison."))
  })
}

///|
async test "MR commit pages keep older selections and escape commit subjects" {
  @web_testkit.with_repository_test_app((port, pool, root, alice_cookie, _) => {
    let git_dir = "\{root}/alice/demo.git"
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let base = @gitops.branch_sha(git_dir, "master")
    let tree = @gitops.merge_git(git_dir, ["rev-parse", "\{base}^{tree}"])
      .trim()
      .to_owned()
    let mut head = base
    let mut oldest = ""
    for i = 0; i < 102; i = i + 1 {
      head = @gitops.merge_git(git_dir, [
          "commit-tree",
          tree,
          "-p",
          head,
          "-m",
          "<script>Commit \{i}</script>",
        ])
        .trim()
        .to_owned()
      if i == 0 {
        oldest = head
      }
    }
    ignore(@gitops.merge_git(git_dir, ["update-ref", "refs/heads/many", head]))
    ignore(
      @collaboration.create_merge_request(
        pool, scope, git_dir, alice, "Paged commits", "", "many", "master", false,
      ),
    )
    let url = "/alice/demo/merge-requests/1?version=1"
    let (status, html) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "&tab=commits",
      alice_cookie,
    )
    assert_eq(status.code, 200)
    assert_true(html.contains("Older commits</a>"))
    assert_true(!html.contains("commit=" + oldest))
    assert_true(html.contains("&lt;script&gt;Commit"))
    assert_true(!html.contains("<script>Commit"))
    let (status, html) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "&tab=commits&commit_page=2",
      alice_cookie,
    )
    assert_eq(status.code, 200)
    assert_true(html.contains("&amp;commit=" + oldest + "&amp;commit_page=2"))
    assert_true(html.contains("Newer commits</a>"))
    assert_true(!html.contains("Older commits</a>"))
    let (status, html) = @web_testkit.http_get_path_with_cookie(
      port,
      url + "&tab=changes&commit=" + oldest,
      alice_cookie,
    )
    assert_eq(status.code, 200)
    assert_true(html.contains("value=\"" + oldest + "\" selected"))
    assert_true(html.contains("commit_page=2&amp;commit=" + oldest))
    assert_true(html.contains("No file changes in this comparison."))
    assert_true(!html.contains("<script>Commit"))
  })
}

///|
async test "large commit subjects do not block all changes or selected small diffs" {
  @web_testkit.with_repository_test_app((port, pool, root, alice_cookie, _) => {
    let git_dir = "\{root}/alice/demo.git"
    let alice = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, alice, {
      owner: "alice",
      name: "demo",
    })
    let base = @gitops.branch_sha(git_dir, "master")
    let first = @test_support.merge_test_commit(
      git_dir, "long", base, "small patch\n",
    )
    let tree = @gitops.merge_git(git_dir, ["rev-parse", "\{first}^{tree}"])
      .trim()
      .to_owned()
    let mut head = first
    let subject = "中".repeat(8000)
    for i = 0; i < 90; i = i + 1 {
      head = @gitops.merge_git(
          git_dir,
          ["commit-tree", tree, "-p", head],
          input="\{subject} \{i}\n",
        )
        .trim()
        .to_owned()
    }
    ignore(@gitops.merge_git(git_dir, ["update-ref", "refs/heads/long", head]))
    ignore(
      @collaboration.create_merge_request(
        pool, scope, git_dir, alice, "Large metadata", "", "long", "master", false,
      ),
    )
    let url = "/alice/demo/merge-requests/1?version=1"
    for
      query in [
        "&tab=changes",
        "&tab=changes&commit=" + first,
        "&tab=changes&commit=" + head,
        "&tab=commits",
      ] {
      let (status, html) = @web_testkit.http_get_path_with_cookie(
        port,
        url + query,
        alice_cookie,
      )
      assert_eq(status.code, 200)
      assert_true(html.length() < 500000)
      assert_true(!html.contains("Git output is too large"))
      if query == "&tab=changes" || query == "&tab=changes&commit=" + first {
        assert_true(html.contains("+small patch"))
      }
      if query == "&tab=changes&commit=" + head {
        assert_true(html.contains("No file changes in this comparison."))
      }
    }
  })
}
