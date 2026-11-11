///|
async test "checkout requires a live authorized attempt and denies stale source credentials" {
  for
    reason in [
      "leased", "expired", "completed", "cancelled", "revoked", "grant", "actor",
    ] {
    with_protocol_fixture((coordinator, pool, root, run, provider, clock) => {
      let id = @protocol.parse_decimal(
        coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
      ).unwrap()
      if reason != "leased" {
        ignore(coordinator.start(id, attempt_secret, 1))
        let archive = coordinator.read_source(root, id, attempt_secret)
        assert_true(archive.length() > 1024)
        assert_true(
          coordinator.read_source_bundle(root, id, attempt_secret).length() >
          100,
        )
      }
      let admin = @identity.active_user_by_name(pool, "admin")
      match reason {
        "expired" => clock.val += @protocol.lease_ms
        "completed" =>
          ignore(coordinator.complete(id, attempt_secret, completion()))
        "cancelled" => coordinator.cancel_run(admin, protocol_repo, run.number)
        "revoked" => coordinator.revoke_provider(admin, provider.id)
        "grant" =>
          coordinator.set_provider_repository(
            admin,
            provider.id,
            protocol_repo,
            false,
          )
        "actor" =>
          pool.with_client(client => {
            ignore(
              client.execute(
                "UPDATE team_member SET role = 'member' WHERE team_id = 1 AND user_id = 1",
              ),
            )
          })
        _ => ()
      }
      try ignore(coordinator.read_source(root, id, attempt_secret)) catch {
        Conflict(_) => ()
        err => raise err
      } noraise {
        _ => fail("stale attempt retrieved source")
      }
      try
        ignore(coordinator.read_source_bundle(root, id, attempt_secret))
      catch {
        Conflict(_) => ()
        err => raise err
      } noraise {
        _ => fail("stale attempt retrieved git bundle")
      }
      try
        ignore(coordinator.read_source_bundle(root, id, provider_secret))
      catch {
        @domain.Unauthorized(_) => ()
        err => raise err
      } noraise {
        _ => fail("provider retrieved git bundle")
      }
      try ignore(coordinator.read_source(root, id, provider_secret)) catch {
        @domain.Unauthorized(_) => ()
        err => raise err
      } noraise {
        _ => fail("provider credential retrieved source")
      }
    })
  }
}

///|
test "checkout rejects reserved paths symlinks and submodules" {
  let hash = "a".repeat(40)
  validate_source_tree(
    "100644 blob \{hash}\tREADME.md\u{0000}100755 blob \{hash}\tbin/build\u{0000}",
  )
  for
    entry in [
      "120000 blob \{hash}\tlink",
      "160000 commit \{hash}\tmodule",
      "100644 blob \{hash}\t.home/.moon/config",
      "100644 blob \{hash}\t.tmp/file",
      "100644 blob \{hash}\t.git/config",
      "120000 blob \{hash}\t.git/config",
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
    if entry != "120000 blob \{hash}\tlink" {
      try validate_source_tree(entry + "\u{0000}", symlinks=true) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("unsafe bundle tree accepted")
      }
    }
  }
}

///|
async test "source bundle preserves symlinks in exactly one pinned commit without repository history" {
  with_protocol_fixture((coordinator, pool, root, original, _, _) => {
    let dir = protocol_repo.git_dir(root)
    let github = @gitops.merge_git(dir, [
        "rev-parse",
        original.commit_sha + ":.github",
      ])
      .trim()
      .to_owned()
    let target = @gitops.merge_git(
        dir,
        ["hash-object", "-w", "--stdin"],
        input=".github/workflows/build.yml",
      )
      .trim()
      .to_owned()
    let loop_blob = @gitops.merge_git(
        dir,
        ["hash-object", "-w", "--stdin"],
        input="loop",
      )
      .trim()
      .to_owned()
    let dangling = @gitops.merge_git(
        dir,
        ["hash-object", "-w", "--stdin"],
        input="missing",
      )
      .trim()
      .to_owned()
    let tree = @gitops.merge_git(
        dir,
        ["mktree"],
        input="040000 tree \{github}\t.github\n120000 blob \{target}\tREADME.md\n120000 blob \{loop_blob}\tloop\n120000 blob \{dangling}\tdangling\n",
      )
      .trim()
      .to_owned()
    let sha = @gitops.merge_git(dir, [
        "commit-tree",
        tree,
        "-p",
        original.commit_sha,
        "-m",
        "Symlink fixture",
      ])
      .trim()
      .to_owned()
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/pipeline", sha]))
    let actor = @identity.active_user_by_name(pool, "alice")
    coordinator.cancel_run(actor, protocol_repo, original.number)
    let run = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    ignore(coordinator.start(id, attempt_secret, 1))
    try ignore(coordinator.read_source(root, id, attempt_secret)) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("tar source accepted symlinks")
    }
    let bundle = coordinator.read_source_bundle(root, id, attempt_secret)
    let scratch = @fs.tmpdir(prefix="moonhub-bundle-test-")
    defer @fs.rmdir(scratch, recursive=true)
    @fs.write_file(scratch + "/source.bundle", bundle)
    assert_eq(
      @process.run("git", [
        "init",
        "--bare",
        "--quiet",
        scratch + "/restored.git",
      ]),
      0,
    )
    assert_eq(
      @process.run(
        "git",
        [
          "--git-dir",
          scratch + "/restored.git",
          "bundle",
          "unbundle",
          scratch + "/source.bundle",
        ],
        stdout=@process.redirect_to_file("/dev/null"),
      ),
      0,
    )
    @fs.write_file(scratch + "/restored.git/shallow", run.commit_sha + "\n")
    let (code, content) = @process.collect_output_merged("git", [
      "--git-dir",
      scratch + "/restored.git",
      "show",
      run.commit_sha + ":.github/workflows/build.yml",
    ])
    assert_eq(code, 0)
    assert_eq(content.text(), run.workflow_source)
    for
      (path, target) in [
        ("README.md", ".github/workflows/build.yml"),
        ("loop", "loop"),
        ("dangling", "missing"),
      ] {
      let (code, content) = @process.collect_output_merged("git", [
        "--git-dir",
        scratch + "/restored.git",
        "show",
        run.commit_sha + ":" + path,
      ])
      assert_eq(code, 0)
      assert_eq(content.text(), target)
      let (code, mode) = @process.collect_output_merged("git", [
        "--git-dir",
        scratch + "/restored.git",
        "ls-tree",
        run.commit_sha,
        path,
      ])
      assert_eq(code, 0)
      assert_true(mode.text().has_prefix("120000 blob "))
    }
    let (code, parents) = @process.collect_output_merged("git", [
      "--git-dir",
      scratch + "/restored.git",
      "rev-list",
      run.commit_sha,
    ])
    assert_eq(code, 0)
    assert_eq(parents.text().trim(), run.commit_sha)
  })
}

///|
async test "contents none is enforced on both source formats even with a live token" {
  with_protocol_fixture(
    (coordinator, _, root, _, _, _) => {
      let assignment = coordinator
        .claim(provider_secret, claim_request())
        .unwrap()
      assert_false(assignment.job.contents_read)
      let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
      ignore(coordinator.start(id, attempt_secret, 1))
      try ignore(coordinator.read_source(root, id, attempt_secret)) catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("permissions-none job received archive")
      }
      try
        ignore(coordinator.read_source_bundle(root, id, attempt_secret))
      catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("permissions-none job received bundle")
      }
    },
    workflow="permissions: {}\n" + @test_support.single_job_workflow,
  )
}
