///|
async test "runner group claims intersect membership repository grants labels and provider scope" {
  let source = @test_support.single_job_workflow.replace_all(
    old="[self-hosted, linux]",
    new="{group: trusted, labels: [self-hosted, linux]}",
  )
  with_protocol_fixture(
    (c, pool, _, run, provider, clock) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      let actor = @identity.active_user_by_name(pool, "alice")
      assert_eq(run.definition.jobs[0].runner_group, "trusted")
      assert_true(c.runtime.claim(provider_secret, claim_request()) is None)
      assert_true(
        c.runtime
        .queue_reasons(actor, protocol_repo, run.number)
        .values()
        .any(reason => reason is @runtime.RunnerGroupUnavailable),
      )
      try
        c.runtime.save_runner_group(actor, "trusted", 0L, [provider.id], [
          protocol_repo,
        ])
      catch {
        @domain.Forbidden(..) => ()
        err => raise err
      } noraise {
        _ => fail("repository owner configured runner group")
      }
      c.runtime.save_runner_group(admin, "trusted", 0L, [provider.id], [])
      assert_true(c.runtime.claim(provider_secret, claim_request()) is None)
      c.runtime.save_runner_group(admin, "trusted", 1L, [provider.id], [
        protocol_repo,
      ])
      try c.runtime.save_runner_group(admin, "trusted", 1L, [], []) catch {
        @runtime.Conflict(_) => ()
        err => raise err
      } noraise {
        _ => fail("stale group update accepted")
      }
      c.runtime.set_provider_scope(
        admin,
        provider.id,
        @runtime.ProviderScope::parse("selected"),
        [],
      )
      assert_true(c.runtime.claim(provider_secret, claim_request()) is None)
      c.runtime.set_provider_scope(
        admin,
        provider.id,
        @runtime.ProviderScope::parse("selected"),
        [protocol_repo],
      )
      c.runtime.set_provider_labels(admin, provider.id, [
        "self-hosted", "windows",
      ])
      assert_true(
        c.runtime.claim(provider_secret, {
          ..claim_request(),
          runner_os: Some("windows"),
        })
        is None,
      )
      c.runtime.set_provider_labels(admin, provider.id, ["self-hosted", "linux"])
      let restarted = @runtime.Coordinator::new(pool, clock=() => clock.val)
      let assignment = restarted
        .claim(provider_secret, claim_request())
        .unwrap()
      let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
      ignore(
        restarted.start(id, attempt_secret, 1, execution_id="1".repeat(32)),
      )
      c.runtime.save_runner_group(admin, "trusted", 2L, [provider.id], [])
      assert_true(restarted.heartbeat(id, attempt_secret, 1).cancel_requested)
      assert_eq(c.runtime.runner_groups(admin)[0].revision, 3L)
      pool.with_client(client => {
        assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
      })
    },
    workflow=source,
  )
}

///|
async test "group-only selection binds the chosen Windows provider OS" {
  let source = @test_support.single_job_workflow.replace_all(
    old="[self-hosted, linux]",
    new="{group: desktop}",
  )
  with_protocol_fixture(
    (c, pool, _, _, provider, _) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      c.runtime.set_provider_labels(admin, provider.id, [
        "self-hosted", "windows",
      ])
      c.runtime.save_runner_group(admin, "desktop", 0L, [provider.id], [
        protocol_repo,
      ])
      let assignment = c.runtime
        .claim(provider_secret, {
          ..claim_request(),
          runner_os: Some("windows"),
        })
        .unwrap()
      assert_eq(assignment.job.runs_on, ["self-hosted", "windows"])
    },
    workflow=source,
  )
}

///|
async test "Ubuntu ARM selector cannot match an x64 provider" {
  let source = @test_support.single_job_workflow.replace_all(
    old="[self-hosted, linux]",
    new="ubuntu-22.04-arm",
  )
  with_protocol_fixture(
    (c, pool, _, run, provider, _) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      let actor = @identity.active_user_by_name(pool, "alice")
      c.runtime.set_provider_labels(admin, provider.id, [
        "self-hosted", "linux", "x64", "ubuntu-22.04",
      ])
      assert_true(c.runtime.claim(provider_secret, claim_request()) is None)
      assert_true(
        c.runtime
        .queue_reasons(actor, protocol_repo, run.number)
        .values()
        .any(reason => reason is @runtime.NoMatchingLabels),
      )
      c.runtime.set_provider_labels(admin, provider.id, [
        "self-hosted", "linux", "arm64", "ubuntu-22.04",
      ])
      let assignment = c.runtime
        .claim(provider_secret, claim_request())
        .unwrap()
      assert_eq(assignment.job.runs_on, [
        "self-hosted", "linux", "arm64", "ubuntu-22.04",
      ])
    },
    workflow=source,
  )
}
