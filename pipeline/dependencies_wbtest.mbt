///|
let dependency_workflow : String =
  #|on: workflow_dispatch
  #|jobs:
  #|  build:
  #|    runs-on: [self-hosted, linux]
  #|    steps: [{uses: actions/checkout@v4, with: {fetch-depth: 0}}]

///|
async test "private action grants pin commits hide credentials and recheck revocation and lease" {
  with_protocol_fixture(
    (c, pool, _, _, _, clock) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      let actor = @identity.active_user_by_name(pool, "alice")
      let assignment = c.runtime
        .claim(provider_secret, claim_request())
        .unwrap()
      assert_eq(assignment.version, @protocol.source_assignment_version)
      let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
      let execution = "1".repeat(32)
      ignore(c.runtime.start(id, attempt_secret, 1, execution_id=execution))
      let grant = c.runtime.dependency_runtime(id, attempt_secret, {
        version: 1,
        execution_id: execution,
      })
      let calls : Array[String] = []
      let download : async (String, String, String, Bool) -> Bytes = (
        target,
        ref_,
        credential,
        archive,
      ) => {
        assert_eq(target, "private/action")
        assert_eq(credential, "github-private-download-value")
        calls.push(ref_)
        if archive {
          b"fixture archive"
        } else {
          @utf8.encode("a".repeat(40))
        }
      }
      assert_true(
        c.runtime.resolve_private_action(
          grant.token,
          "private/action",
          "v1",
          download~,
        )
        is None,
      )
      assert_true(calls.is_empty())
      try
        @runtime.save_dependency_grant(
          pool,
          actor,
          protocol_repo,
          "github",
          "private/action",
          "",
          Some("github-private-download-value"),
          0L,
        )
      catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("non-admin shared credential")
      }
      @runtime.save_dependency_grant(
        pool,
        admin,
        protocol_repo,
        "github",
        "private/action",
        "",
        Some("github-private-download-value"),
        0L,
      )
      assert_true(
        !@runtime.dependency_grants(pool, admin, protocol_repo)
        .stringify()
        .contains("github-private-download-value"),
      )
      assert_eq(
        c.runtime.resolve_private_action(
          grant.token,
          "private/action",
          "v1",
          download~,
        ),
        Some("a".repeat(40)),
      )
      let restarted = @runtime.Coordinator::new(pool, clock=() => clock.val)
      assert_eq(
        restarted.resolve_private_action(
          grant.token,
          "private/action",
          "v1",
          download~,
        ),
        Some("a".repeat(40)),
      )
      assert_eq(calls, ["v1"])
      assert_eq(
        restarted.private_action_archive(
          grant.token,
          "private/action",
          "v1",
          download~,
        ),
        b"fixture archive",
      )
      assert_eq(calls, ["v1", "a".repeat(40)])
      try
        ignore(
          restarted.private_action_archive(
            grant.token,
            "private/other",
            "v1",
            download~,
          ),
        )
      catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("download crossed repository scope")
      }
      @runtime.save_dependency_grant(
        pool,
        admin,
        protocol_repo,
        "github",
        "private/action",
        "",
        None,
        1L,
        delete=true,
      )
      try
        ignore(
          restarted.private_action_archive(
            grant.token,
            "private/action",
            "v1",
            download~,
          ),
        )
      catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("revoked grant downloaded cached commit")
      }
      clock.val += @protocol.lease_ms
      try
        ignore(
          restarted.resolve_private_action(
            grant.token,
            "private/action",
            "v1",
            download~,
          ),
        )
      catch {
        @domain.Unauthorized(_) => ()
        err => raise err
      } noraise {
        _ => fail("expired runtime accessed dependencies")
      }
    },
    workflow=dependency_workflow,
  )
}

///|
async test "full history includes ancestral tags and secondary source grants pin exact refs" {
  with_protocol_fixture(
    (c, pool, root, original, _, _) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let admin = @identity.active_user_by_name(pool, "admin")
      let dir = protocol_repo.git_dir(root)
      let sha = @gitops.merge_git(dir, [
          "commit-tree",
          original.commit_sha + "^{tree}",
          "-p",
          original.commit_sha,
          "-m",
          "Release change",
        ])
        .trim()
        .to_owned()
      ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/pipeline", sha]))
      ignore(
        @gitops.merge_git(dir, [
          "update-ref",
          "refs/tags/v1.0.0",
          original.commit_sha,
        ]),
      )
      c.runtime.cancel_run(actor, protocol_repo, original.number)
      let run = create_run(
        pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
      )
      let id = @protocol.parse_decimal(
        c.runtime.claim(provider_secret, claim_request()).unwrap().attempt_id,
      ).unwrap()
      ignore(
        c.runtime.start(id, attempt_secret, 1, execution_id="2".repeat(32)),
      )
      let grant = c.runtime.dependency_runtime(id, attempt_secret, {
        version: 1,
        execution_id: "2".repeat(32),
      })
      let (pinned, bundle) = c.runtime.dependency_source(
        root,
        grant.token,
        "alice/demo",
        run.commit_sha,
        true,
      )
      assert_eq(pinned, sha)
      let temporary = @fs.tmpdir(prefix="moonhub-history-test-")
      defer @fs.rmdir(temporary, recursive=true)
      @fs.write_file(temporary + "/source.bundle", bundle)
      assert_eq(
        @process.run("git", [
          "clone",
          "--quiet",
          "--bare",
          temporary + "/source.bundle",
          temporary + "/history.git",
        ]),
        0,
      )
      assert_eq(
        @gitops.merge_git(temporary + "/history.git", [
          "rev-list", "--count", sha,
        ]).trim(),
        "2",
      )
      assert_true(
        @gitops.merge_git(temporary + "/history.git", [
          "describe", "--tags", sha,
        ])
        .trim()
        .has_prefix("v1.0.0-1-g"),
      )
      try
        ignore(
          c.runtime.dependency_source(
            root,
            grant.token,
            "alice/demo",
            original.commit_sha,
            true,
          ),
        )
      catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("primary checkout changed run commit")
      }
      let secondary : @domain.RepoId = { owner: "bob", name: "dependency", }
      @fs.mkdir(root + "/bob")
      assert_eq(
        @process.run("git", [
          "clone",
          "--quiet",
          "--bare",
          dir,
          secondary.git_dir(root),
        ]),
        0,
      )
      pool.with_client(client => {
        ignore(
          client.execute(
            "INSERT INTO repository(team_id,name,visibility) VALUES(2,'dependency','private')",
          ),
        )
      })
      try
        ignore(
          c.runtime.dependency_source(
            root,
            grant.token,
            "bob/dependency",
            "refs/heads/pipeline",
            false,
          ),
        )
      catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("primary grant accessed secondary repository")
      }
      @runtime.save_dependency_grant(
        pool,
        admin,
        protocol_repo,
        "moonhub",
        "bob/dependency",
        "refs/heads/pipeline",
        None,
        0L,
      )
      assert_eq(
        c.runtime.dependency_source(
          root,
          grant.token,
          "bob/dependency",
          "refs/heads/pipeline",
          false,
        ).0,
        sha,
      )
      ignore(
        @gitops.merge_git(secondary.git_dir(root), [
          "update-ref",
          "refs/heads/pipeline",
          original.commit_sha,
        ]),
      )
      assert_eq(
        c.runtime.dependency_source(
          root,
          grant.token,
          "bob/dependency",
          "refs/heads/pipeline",
          false,
        ).0,
        sha,
      )
      try
        ignore(
          c.runtime.dependency_source(
            root,
            grant.token,
            "bob/dependency",
            "refs/tags/v1.0.0",
            false,
          ),
        )
      catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("source grant accessed another ref")
      }
      @runtime.save_dependency_grant(
        pool,
        admin,
        protocol_repo,
        "moonhub",
        "bob/dependency",
        "refs/heads/pipeline",
        None,
        1L,
        delete=true,
      )
      try
        ignore(
          c.runtime.dependency_source(
            root,
            grant.token,
            "bob/dependency",
            "refs/heads/pipeline",
            false,
          ),
        )
      catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("revoked source grant survived snapshot")
      }
    },
    workflow=dependency_workflow,
  )
}
