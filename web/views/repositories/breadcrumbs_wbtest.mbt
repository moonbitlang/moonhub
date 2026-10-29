///|
async test "file breadcrumbs navigate ancestors at the selected revision and parent rows ascend one level" {
  @test_support.with_git_test_repo((root, git_dir) => {
    let original = @gitops.run_git(git_dir, ["rev-parse", "master"])
      .trim()
      .to_owned()
    let blob = @gitops.run_git(git_dir, ["rev-parse", "master:README.md"])
      .trim()
      .to_owned()
    let mut tree = @gitops.merge_git(
        git_dir,
        ["mktree"],
        input="100644 blob \{blob}\tmain.mbt\n",
      )
      .trim()
      .to_owned()
    // Literal percent escapes must not turn into a different path on navigation.
    let directory = "文档 %23 #?&<name>"
    for name in [directory, "src"] {
      tree = @gitops.merge_git(
          git_dir,
          ["mktree", "-z"],
          input="040000 tree \{tree}\t\{name}\u{0}",
        )
        .trim()
        .to_owned()
    }
    let commit = @gitops.merge_git(git_dir, [
        "commit-tree", tree, "-p", original, "-m", "Nested breadcrumb fixture",
      ])
      .trim()
      .to_owned()
    for
      reference in [
        "refs/heads/feature/breadcrumbs", "refs/tags/releases/v3", "refs/heads/feature/%23+中文",
      ] {
      ignore(@gitops.run_git(git_dir, ["update-ref", reference, commit]))
    }
    let app = @moonback.App(
      @web_testkit.browser_app_module,
      config=@web_testkit.test_app_config(repo_root=root),
    )
    defer app.close()
    @async.with_task_group(group => {
      let server = @moonback.listen(port=0)
      let task = group.spawn(() => app.serve(server))
      defer task.cancel()
      let port = server.addr.port()
      for path in ["%2E%2E", "%FF", "%GG"] {
        let (response, _) = @web_testkit.http_get_path(
          port,
          "/alice/demo/tree/feature/breadcrumbs/\{path}",
        )
        assert_eq(response.code, 400)
      }
      for
        rev in [
          "feature/breadcrumbs", "releases/v3", "feature/%23+中文", commit,
        ] {
        let rev = @web_context.url_escape_path(rev)
        let base = "/alice/demo/tree/\{rev}"
        let encoded = @web_context.url_escape_path(directory)
        for kind in ["tree", "blob"] {
          let path = if kind == "tree" {
            "src/\{encoded}"
          } else {
            "src/\{encoded}/main.mbt"
          }
          let (response, html) = @web_testkit.http_get_path(
            port,
            "/alice/demo/\{kind}/\{rev}/\{path}",
          )
          assert_eq(response.code, 200, msg=html)
          let trail = html.split("aria-label=\"File path\"><ol>").collect()[1]
          let trail = trail[:trail.find("</nav>").unwrap()]
          assert_true(trail.contains("href=\"\{base}\""))
          assert_true(trail.contains("href=\"\{base}/src\""))
          assert_true(trail.contains("aria-current=\"page\""))
          assert_true(trail.contains("&lt;name&gt;"))
          assert_true(!trail.contains("<name>"))
          if kind == "blob" {
            assert_true(trail.contains("href=\"\{base}/src/\{encoded}\""))
            assert_true(trail.contains(">main.mbt</span></h2>"))
          } else {
            assert_true(
              html.contains(
                "href=\"\{base}/src\" aria-label=\"Parent directory\"",
              ),
            )
          }
        }
        // Follow the targets rather than only checking their spelling.
        for
          href in [
            base,
            "\{base}/src",
            "\{base}/src/\{@web_context.url_escape_path(directory)}",
          ] {
          let (response, _) = @web_testkit.http_get_path(port, href)
          assert_eq(response.code, 200, msg=href)
        }
        let (_, parent) = @web_testkit.http_get_path(port, "\{base}/src")
        assert_true(
          parent.contains("href=\"\{base}\" aria-label=\"Parent directory\""),
        )
        let (_, root_page) = @web_testkit.http_get_path(port, base)
        assert_true(!root_page.contains("aria-label=\"Parent directory\""))
        assert_true(root_page.contains("<h2 aria-current=\"page\">"))
      }
    })
  })
}
