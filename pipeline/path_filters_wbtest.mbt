///|
async fn filter_test_tree(
  dir : String,
  files : Array[(String, String)],
) -> String {
  let directories : Map[String, Array[(String, String)]] = Map([])
  let entries : Array[String] = []
  for (path, content) in files {
    if path.split_once("/") is Some((head, tail)) {
      let group = directories.get_or_default(head.to_owned(), [])
      group.push((tail.to_owned(), content))
      directories[head.to_owned()] = group
    } else {
      let blob = @gitops.merge_git(
          dir,
          ["hash-object", "-w", "--stdin"],
          input=content,
        )
        .trim()
        .to_owned()
      entries.push("100644 blob \{blob}\t\{path}\n")
    }
  }
  for name, group in directories {
    let tree = filter_test_tree(dir, group)
    entries.push("040000 tree \{tree}\t\{name}\n")
  }
  @gitops.merge_git(dir, ["mktree"], input=entries.join("")).trim().to_owned()
}

///|
async fn filter_test_commit(
  dir : String,
  parent : String,
  branch : String,
  files : Array[(String, String)],
) -> String {
  let tree = filter_test_tree(dir, files)
  let args = ["commit-tree", tree, "-m", "path fixture"]
  if !parent.is_empty() {
    args.append(["-p", parent])
  }
  let sha = @gitops.merge_git(dir, args).trim().to_owned()
  ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/" + branch, sha]))
  sha
}

///|
async test "push path filtering uses immutable before and after snapshots including rename and deletion" {
  @test_support.with_repository_test_data((pool, root) => {
    let repo = protocol_repo
    let actor = @identity.active_user_by_name(pool, "alice")
    let dir = repo.git_dir(root)
    let workflow = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {push: {branches: [main], paths: ['tools_sdk/**']}}",
    )
    let base_files = [
      (".github/workflows/build.yml", workflow),
      ("tools_sdk/old.mbt", "same"),
      ("README.md", "base"),
    ]
    let base = filter_test_commit(dir, "", "main", base_files)
    @repository.set_pipeline_push_enabled(pool, root, actor, repo, true)
    let unmatched = filter_test_commit(dir, base, "main", [
      (".github/workflows/build.yml", workflow),
      ("tools_sdk/old.mbt", "same"),
      ("README.md", "changed"),
    ])
    let renamed = filter_test_commit(dir, unmatched, "main", [
      (".github/workflows/build.yml", workflow),
      ("other/new.mbt", "same"),
      ("README.md", "changed"),
    ])
    for (old, head, key) in [(base, unmatched, "a"), (unmatched, renamed, "b")] {
      @repository.record_received_transaction(
        pool,
        actor,
        repo,
        key.repeat(32),
        "prepared",
        "\{old} \{head} refs/heads/main",
      )
      @repository.record_received_transaction(
        pool,
        actor,
        repo,
        key.repeat(32),
        "committed",
        "\{old} \{head} refs/heads/main",
      )
    }
    // Both events are consumed after main already points at the renamed tree.
    assert_true(run_next_push_event(pool, root))
    assert_true(run_next_push_event(pool, root))
    let runs = list_runs(pool, actor, repo)
    assert_eq(runs.length(), 1)
    assert_eq(runs[0].commit_sha, renamed)
    let changes = changed_paths(dir, unmatched, renamed).unwrap()
    assert_true(changes.contains("tools_sdk/old.mbt"))
    assert_true(changes.contains("other/new.mbt"))
    let deleted = filter_test_commit(dir, renamed, "main", [
      (".github/workflows/build.yml", workflow),
      ("README.md", "changed"),
    ])
    assert_true(
      changed_paths(dir, renamed, deleted).unwrap().contains("other/new.mbt"),
    )
    assert_eq(changed_paths(dir, base, base), Some([]))
    assert_true(changed_paths(dir, "0".repeat(40), renamed) is None)
    assert_true(changed_paths(dir, "f".repeat(40), renamed) is None)
  })
}

///|
async test "automatic PR discovery respects base branch and changed file filters" {
  for
    (options, expected) in [
      ("branches: [master], paths: [README.md]", 1),
      ("branches: [other], paths: [README.md]", 0),
      ("branches: [master], paths: ['tools_sdk/**']", 0),
      ("branches: [master], paths-ignore: [README.md]", 0),
    ] {
    let source = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {pull_request: {" + options + "}}",
    )
    with_merge_check_fixture(
      (pool, root, _, actor, mr) => {
        poll_merge_checks(pool, root)
        assert_eq(
          list_runs(pool, actor, protocol_repo).length(),
          expected,
          msg=options,
        )
        assert_eq(
          @collaboration.merge_checks(pool, mr).length(),
          expected,
          msg=options,
        )
      },
      workflow=source,
      required=false,
    )
  }
}

///|
async test "PR paths compare against the merge base rather than target-only changes" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, protocol_repo)
    let dir = protocol_repo.git_dir(root)
    let source = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on: {pull_request: {paths: ['tools_sdk/**']}}",
    )
    let base = filter_test_commit(dir, "", "master", [
      (".github/workflows/build.yml", source),
      ("tools_sdk/main.mbt", "base"),
      ("README.md", "base"),
    ])
    ignore(
      filter_test_commit(dir, base, "feature", [
        (".github/workflows/build.yml", source),
        ("tools_sdk/main.mbt", "base"),
        ("README.md", "feature"),
      ]),
    )
    ignore(
      filter_test_commit(dir, base, "master", [
        (".github/workflows/build.yml", source),
        ("tools_sdk/main.mbt", "target-only"),
        ("README.md", "base"),
      ]),
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, dir, actor, "filter", "", "feature", "master", false,
    )
    poll_merge_checks(pool, root)
    assert_true(list_runs(pool, actor, protocol_repo).is_empty())
    assert_true(@collaboration.merge_checks(pool, mr).is_empty())
  })
}

///|
async test "repository required checks do not disappear behind workflow path filters" {
  let source = @test_support.single_job_workflow.replace_all(
    old="on: workflow_dispatch",
    new="on: {pull_request: {paths: ['tools_sdk/**']}}",
  )
  with_merge_check_fixture(
    (pool, root, _, actor, mr) => {
      poll_merge_checks(pool, root)
      assert_eq(list_runs(pool, actor, protocol_repo).length(), 1)
      assert_true(@collaboration.merge_checks(pool, mr)[0].required)
    },
    workflow=source,
    required=true,
  )
}
