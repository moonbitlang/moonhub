///|
async test "structured commit view pins the current file while pagination clears it" {
  let executor = @gitops.DiffExecutor::new(
    worker="_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe",
  )
  @web_testkit.with_repository_test_app(
    (port, _, root, cookie, _) => {
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let dir = repo.git_dir(root)
      let (base, head) = @test_support.structured_diff_fixture(dir)
      let manifest = executor.manifest(dir, base, head, page=2)
      let file = manifest.files
        .iter()
        .find_first(f => f.new_path == "z-add.txt")
        .unwrap()
      let view_url = "/alice/demo/commit/\{head}?fixed=1&page=2&file_id=\{file.id}"
      for mode in ["lexical", "ast", "line"] {
        let (response, html) = @web_testkit.http_get_path_with_cookie(
          port,
          view_url + "&mode=\{mode}&ignore_comments=false&ignore_tests=true",
          cookie,
        )
        assert_eq(response.code, 200)
        assert_eq(
          @web_testkit.extract_attr(
            html, "moonhub-structured-diff", "data-view-url=\"",
          ).replace_all(old="&amp;", new="&"),
          view_url,
        )
        assert_eq(
          @web_testkit.extract_attr(
            html, "moonhub-structured-diff", "data-page-url=\"",
          ).replace_all(old="&amp;", new="&"),
          "/alice/demo/commit/\{head}?fixed=1",
        )
        for next in ["lexical", "ast", "line"] {
          let link = view_url +
            "&mode=\{next}&ignore_comments=false&ignore_tests=true#diff-code"
          assert_true(
            html.contains("href=\"\{link.replace_all(old="&", new="&amp;")}\""),
          )
        }
        assert_true(
          html.contains(
            "&quot;mode&quot;:&quot;\{mode}&quot;,&quot;ignore_comments&quot;:false,&quot;ignore_tests&quot;:true",
          ),
        )
        assert_true(
          html.contains(
            "&amp;page=1&amp;mode=\{mode}&amp;ignore_comments=false&amp;ignore_tests=true\">Previous files</a>",
          ),
        )
        assert_true(html.contains("</nav></div></moonhub-structured-diff>"))
      }
    },
    moondiff=true,
    diff_executor=executor,
  )
}

///|
test "streamed patch markup is escaped without corrupting UTF-8 boundaries" {
  assert_eq(
    escape_html_text_chunk(b"</pre><script>&lt; & text</script>"),
    b"&lt;/pre&gt;&lt;script&gt;&amp;lt; &amp; text&lt;/script&gt;",
  )
  let source = @utf8.encode("<\u{4e2d}\u{6587}> & \u{1f600}")
  let result : Array[Byte] = []
  for byte in source {
    result.append(escape_html_text_chunk(Bytes::from_array([byte])).to_array())
  }
  assert_eq(
    @utf8.decode(Bytes::from_array(result)),
    "&lt;\u{4e2d}\u{6587}&gt; &amp; \u{1f600}",
  )
}

///|
async test "commit changes escape patch content and normalize merge patches" {
  @test_support.with_git_test_repo((root, git_dir) => {
    let original = @gitops.run_git(git_dir, ["rev-parse", "master"])
      .trim()
      .to_owned()
    let source = @test_support.merge_test_commit(
      git_dir, "html-patch", original, "</pre><script>window.patchExecuted = true</script>\n<div>A &amp; B</div>\n",
    )
    let tree = @gitops.run_git(git_dir, ["rev-parse", "\{source}^{tree}"])
      .trim()
      .to_owned()
    let merged = @gitops.merge_git(git_dir, [
        "commit-tree", tree, "-p", original, "-p", source, "-m", "Merge HTML changes",
      ])
      .trim()
      .to_owned()
    let empty = @gitops.merge_git(git_dir, [
        "commit-tree", tree, "-p", merged, "-m", "No content changes",
      ])
      .trim()
      .to_owned()
    // Repository preferences must not change the parser's expected patch format.
    ignore(@gitops.run_git(git_dir, ["config", "color.ui", "always"]))
    ignore(@gitops.run_git(git_dir, ["config", "diff.noprefix", "true"]))
    let app = @moonback.App(
      @web_testkit.browser_app_module,
      config=@web_testkit.test_app_config(repo_root=root),
    )
    defer app.close()
    @async.with_task_group(group => {
      let server = @moonback.listen(port=0)
      let task = group.spawn(() => app.serve(server))
      defer task.cancel()
      for commit in [source, merged] {
        let (response, html) = @web_testkit.http_get_path(
          server.addr.port(),
          "/alice/demo/commit/\{commit}",
        )
        assert_eq(response.code, 200)
        assert_true(html.contains("<h2>Changes</h2>"))
        assert_true(
          html.contains(
            "<pre data-patch=\"\">diff --git a/README.md b/README.md",
          ),
        )
        assert_true(
          html.contains(
            "+&lt;/pre&gt;&lt;script&gt;window.patchExecuted = true&lt;/script&gt;",
          ),
        )
        assert_true(html.contains("+&lt;div&gt;A &amp;amp; B&lt;/div&gt;"))
        assert_true(!html.contains("<script>window.patchExecuted"))
        assert_true(!html.contains("diff --cc "))
        assert_true(!html.contains("\u{1b}["))
      }
      let (response, html) = @web_testkit.http_get_path(
        server.addr.port(),
        "/alice/demo/commit/\{empty}",
      )
      assert_eq(response.code, 200)
      assert_true(html.contains("No file changes."))
      assert_true(!html.contains("<moonhub-commit-diff>"))
    })
  })
}
