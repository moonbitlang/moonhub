///|
async test "merge request HTTP routes enforce CSRF roles and current revision" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, bob) => {
    let git_dir = "\{root}/alice/demo.git"
    ignore(
      @test_support.merge_test_commit(
        git_dir,
        "feature",
        @gitops.branch_sha(git_dir, "master"),
        "source\n",
      ),
    )
    let (forbidden, _) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests", bob,
    )
    assert_eq(forbidden.code, 404)
    let (page, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/new", alice,
    )
    assert_eq(page.code, 200)
    let token = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    let form = "title=Review&source=feature&target=master"
    let (invalid, _) = @web_testkit.http_post_path_with_cookie(
      port, "/alice/demo/merge-requests", form, alice,
    )
    assert_eq(invalid.code, 403)
    let (created, body) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/merge-requests",
      "csrf_token=\{token}&\{form}",
      alice,
    )
    assert_eq(created.code, 303, msg=body)
    let (detail, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/1", alice,
    )
    assert_eq(detail.code, 200)
    assert_true(detail.headers.get("cache-control") is Some("no-store"))
    assert_true(html.contains("Review"))
    let token = @web_testkit.extract_attr(
      html, "name=\"csrf_token\"", "value=\"",
    )
    let (self_review, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/merge-requests/1/review",
      "csrf_token=\{token}&version=1&decision=approved",
      alice,
    )
    assert_eq(self_review.code, 403)
    let (commented, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/merge-requests/1/review",
      "csrf_token=\{token}&version=1&decision=comment&body=%3Cscript%3Ebad%3C%2Fscript%3E",
      alice,
    )
    assert_eq(commented.code, 303)
    let (_, discussion) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/1", alice,
    )
    assert_true(discussion.contains("&lt;script&gt;bad&lt;/script&gt;"))
    assert_true(!discussion.contains("<script>bad</script>"))
    let (changes, diff) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/1?tab=changes", alice,
    )
    assert_eq(changes.code, 200)
    assert_true(diff.contains("data-inline-review=\"\"><pre data-patch=\"\">"))
    let (queued, _) = @web_testkit.http_post_path_with_cookie(
      port,
      "/alice/demo/merge-requests/1/merge",
      "csrf_token=\{token}&version=1",
      alice,
    )
    assert_eq(queued.code, 303)
    assert_true(@collaboration.run_next_merge_job(pool, root))
    let (_, merged) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/1", alice,
    )
    assert_true(merged.contains("Merged as"))
  })
}

///|
async test "MR descriptions discussion roots and replies link local references" {
  @web_testkit.with_repository_test_app((port, pool, root, cookie, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, {
      owner: "alice",
      name: "demo",
    })
    let git_dir = scope.repo.git_dir(root)
    ignore(
      @test_support.merge_test_commit(
        git_dir,
        "feature",
        @gitops.branch_sha(git_dir, "master"),
        "references\n",
      ),
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, git_dir, actor, "References", "See #34 and !12", "feature", "master",
      false,
    )
    @collaboration.submit_merge_review(
      pool,
      actor,
      mr,
      mr.version,
      "comment",
      "Related #56 and !78",
    )
    let root = @collaboration.list_merge_discussions(pool, scope, actor, mr, 1L)[0]
    ignore(
      @collaboration.reply_merge_discussion(
        pool,
        scope,
        actor,
        mr,
        root.id,
        "Reply #90 and !21",
      ),
    )
    let (response, html) = @web_testkit.http_get_path_with_cookie(
      port, "/alice/demo/merge-requests/1", cookie,
    )
    assert_eq(response.code, 200)
    for
      path in [
        "issues/34", "merge-requests/12", "issues/56", "merge-requests/78", "issues/90",
        "merge-requests/21",
      ] {
      assert_true(html.contains("href=\"/alice/demo/\{path}\""), msg=path)
    }
  })
}
