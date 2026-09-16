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
  with_git_test_repo((root, git_dir) => {
    let original = run_git(git_dir, ["rev-parse", "master"]).trim().to_owned()
    let source = merge_test_commit(
      git_dir, "html-patch", original, "</pre><script>window.patchExecuted = true</script>\n<div>A &amp; B</div>\n",
    )
    let tree = run_git(git_dir, ["rev-parse", "\{source}^{tree}"])
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
    ignore(run_git(git_dir, ["config", "color.ui", "always"]))
    ignore(run_git(git_dir, ["config", "diff.noprefix", "true"]))
    let app = @moonback.App(
      browser_app_module,
      config=test_app_config(repo_root=root),
    )
    defer app.close()
    @async.with_task_group(group => {
      let server = @moonback.listen(port=0)
      let task = group.spawn(() => app.serve(server))
      defer task.cancel()
      for commit in [source, merged] {
        let (response, html) = http_get_path(
          server.addr.port(),
          "/alice/demo/commit/\{commit}",
        )
        assert_eq(response.code, 200)
        assert_true(html.contains("<h2>Changes</h2>"))
        assert_true(
          html.contains("<pre data-patch>diff --git a/README.md b/README.md"),
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
      let (response, html) = http_get_path(
        server.addr.port(),
        "/alice/demo/commit/\{empty}",
      )
      assert_eq(response.code, 200)
      assert_true(html.contains("No file changes."))
      assert_true(!html.contains("<moonhub-commit-diff>"))
    })
  })
}
