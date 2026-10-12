///|
async test "all-repository scope unblocks queued work and narrowing cancels unauthorized running work" {
  with_protocol_fixture((coordinator, pool, _, run, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    coordinator.set_provider_scope(admin, provider.id, SelectedRepositories, [])
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    coordinator.set_provider_scope(admin, provider.id, AllRepositories, [])
    let current = coordinator.list_providers(admin)[0]
    assert_eq(current.scope, AllRepositories)
    assert_true(current.repositories.is_empty())
    assert_eq(current.name, provider.name)
    assert_eq(current.labels, ["linux", "self-hosted"])
    let attempt = coordinator.claim(provider_secret, claim_request()).unwrap()
    assert_eq(attempt.run_id, run.id.to_string())
    let id = @protocol.parse_decimal(attempt.attempt_id).unwrap()
    assert_false(coordinator.start(id, attempt_secret, 1).cancel_requested)
    assert_false(coordinator.heartbeat(id, attempt_secret, 1).cancel_requested)
    coordinator.set_provider_scope(admin, provider.id, SelectedRepositories, [
      protocol_repo,
    ])
    assert_false(coordinator.heartbeat(id, attempt_secret, 1).cancel_requested)
    coordinator.set_provider_scope(admin, provider.id, SelectedRepositories, [])
    assert_true(coordinator.heartbeat(id, attempt_secret, 1).cancel_requested)
    coordinator.authenticate_provider(provider_secret)
  })
}

///|
async test "scope edits enforce administrator privileges and preserve old state on failure" {
  with_protocol_fixture((coordinator, pool, _, _, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let alice = @identity.active_user_by_name(pool, "alice")
    try
      coordinator.set_provider_scope(alice, provider.id, AllRepositories, [])
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("non-admin expanded scope")
    }
    try
      coordinator.set_provider_scope(admin, provider.id, SelectedRepositories, [
        { owner: "alice", name: "missing", },
      ])
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("granted nonexistent repository")
    }
    assert_eq(coordinator.list_providers(admin)[0].scope, SelectedRepositories)
    assert_eq(coordinator.list_providers(admin)[0].repositories, ["alice/demo"])
    coordinator.set_provider_paused(admin, provider.id, true)
    coordinator.set_provider_scope(admin, provider.id, AllRepositories, [])
    assert_true(coordinator.list_providers(admin)[0].paused)
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    coordinator.revoke_provider(admin, provider.id)
    for id in [provider.id, provider.id + 99L] {
      try
        coordinator.set_provider_scope(admin, id, SelectedRepositories, [])
      catch {
        @domain.NotFound(_) => ()
        err => raise err
      } noraise {
        _ => fail("edited missing or revoked provider")
      }
    }
  })
}

///|
async test "scope is preserved by ordinary ensure and changed only with an explicit scope" {
  with_protocol_fixture((coordinator, pool, _, _, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let labels = ["self-hosted", "linux"]
    coordinator.set_provider_scope(admin, provider.id, AllRepositories, [])
    assert_eq(
      coordinator.ensure_provider(
        admin,
        provider.name,
        provider_secret,
        labels,
        [],
      ).scope,
      AllRepositories,
    )
    assert_eq(
      coordinator.ensure_provider(
        admin,
        provider.name,
        provider_secret,
        labels,
        [protocol_repo],
        scope=Some(SelectedRepositories),
      ).scope,
      SelectedRepositories,
    )
    let created = coordinator.create_provider(
      admin,
      "shared",
      "c".repeat(64),
      labels,
      [],
      scope=AllRepositories,
    )
    assert_eq(created.scope, AllRepositories)
    let ensured = coordinator.ensure_provider(
      admin,
      "shared-ensure",
      "d".repeat(64),
      labels,
      [],
      scope=Some(AllRepositories),
    )
    assert_eq(ensured.scope, AllRepositories)
    try
      coordinator.set_provider_repository(
        admin,
        created.id,
        protocol_repo,
        false,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("silently revoked a grant on a shared provider")
    }
    try
      coordinator.set_provider_scope(admin, created.id, AllRepositories, [
        protocol_repo,
      ])
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted contradictory scope")
    }
  })
}

///|
async test "queue diagnostics explain missing grants labels paused busy and recent contact" {
  with_protocol_fixture((coordinator, pool, root, run, provider, clock) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let key = "build"
    coordinator.set_provider_scope(admin, provider.id, SelectedRepositories, [])
    assert_eq(
      coordinator.queue_reasons(admin, protocol_repo, run.number)[key],
      NoAuthorizedProvider,
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO pipeline_job_label (job_id, label) SELECT id, 'moonhub-build' FROM pipeline_job WHERE run_id = ?",
          params=[run.id],
        ),
      )
    })
    coordinator.set_provider_scope(admin, provider.id, AllRepositories, [])
    assert_eq(
      coordinator.queue_reasons(admin, protocol_repo, run.number)[key],
      NoMatchingLabels,
    )
    coordinator.set_provider_labels(admin, provider.id, [
      "self-hosted", "linux", "moonhub-build",
    ])
    coordinator.set_provider_paused(admin, provider.id, true)
    assert_eq(
      coordinator.queue_reasons(admin, protocol_repo, run.number)[key],
      ProvidersPaused,
    )
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    coordinator.set_provider_paused(admin, provider.id, false)
    assert_eq(
      coordinator.queue_reasons(admin, protocol_repo, run.number)[key],
      AwaitingClaim,
    )
    assert_true(coordinator.list_providers(admin)[0].online)
    clock.val += provider_contact_window_ms
    assert_false(coordinator.list_providers(admin)[0].online)
    assert_eq(
      coordinator.queue_reasons(admin, protocol_repo, run.number)[key],
      NoRecentProviderContact,
    )
    let attempt = coordinator.claim(provider_secret, claim_request()).unwrap()
    ignore(
      coordinator.start(
        @protocol.parse_decimal(attempt.attempt_id).unwrap(),
        attempt_secret,
        1,
      ),
    )
    let queued = create_run(
      pool, root, admin, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    assert_eq(
      coordinator.queue_reasons(admin, protocol_repo, queued.number)[key],
      ProvidersBusy,
    )
    assert_true(
      coordinator.queue_reasons(admin, protocol_repo, run.number).is_empty(),
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE team_member SET role = 'member' WHERE team_id = 1 AND user_id = 1",
        ),
      )
    })
    assert_true(
      coordinator.heartbeat(
        @protocol.parse_decimal(attempt.attempt_id).unwrap(),
        attempt_secret,
        1,
      ).cancel_requested,
    )
  })
}

///|
async test "queue diagnostics remain authorized and distinguish dependency waiting" {
  with_dag_fixture((coordinator, pool, repo, run, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let reasons = coordinator.queue_reasons(admin, repo, run.number)
    assert_eq(reasons["test"], WaitingDependencies)
    assert_eq(reasons["deploy"], WaitingDependencies)
    assert_eq(reasons["build"], NoRecentProviderContact)
    try
      ignore(
        coordinator.queue_reasons(
          @identity.active_user_by_name(pool, "bob"),
          repo,
          run.number,
        ),
      )
    catch {
      @domain.NotFound(_) | @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("exposed another repository queue")
    }
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE team_member SET role = 'member' WHERE team_id = 1 AND user_id = 1",
        ),
      )
    })
    assert_eq(
      coordinator.queue_reasons(admin, repo, run.number)["build"],
      RequesterUnavailable,
    )
  })
}

///|
async test "deployment ensure preserves administrator settings despite stale bootstrap configuration" {
  with_protocol_fixture((coordinator, pool, _, _, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    coordinator.set_provider_scope(admin, provider.id, AllRepositories, [])
    coordinator.set_provider_labels(admin, provider.id, [
      "self-hosted", "linux", "moonhub-build",
    ])
    coordinator.set_provider_paused(admin, provider.id, true)
    for _ in 0..<2 {
      let existing = coordinator.ensure_provider(
        admin,
        provider.name,
        provider_secret,
        ["self-hosted", "linux", "old-label"],
        [{ owner: "missing", name: "old-repository", }],
        scope=Some(SelectedRepositories),
        preserve_existing=true,
      )
      assert_eq(existing.id, provider.id)
      assert_eq(existing.scope, AllRepositories)
      assert_eq(existing.labels, ["linux", "moonhub-build", "self-hosted"])
      assert_true(existing.paused)
      assert_true(existing.repositories.is_empty())
    }
    coordinator.set_provider_scope(admin, provider.id, SelectedRepositories, [])
    let existing = coordinator.ensure_provider(
      admin,
      provider.name,
      provider_secret,
      ["self-hosted", "linux"],
      [protocol_repo],
      scope=Some(AllRepositories),
      preserve_existing=true,
    )
    assert_eq(existing.scope, SelectedRepositories)
    assert_true(existing.repositories.is_empty())
    let created = coordinator.ensure_provider(
      admin,
      "bootstrap",
      "c".repeat(64),
      ["self-hosted", "linux"],
      [protocol_repo],
      scope=Some(SelectedRepositories),
      preserve_existing=true,
    )
    assert_eq(created.repositories, ["alice/demo"])
    assert_eq(created.labels, ["linux", "self-hosted"])
    try
      coordinator.ensure_provider(
        admin,
        provider.name,
        "d".repeat(64),
        ["self-hosted", "linux"],
        [],
        preserve_existing=true,
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("preserve replaced credential")
    }
    coordinator.revoke_provider(admin, provider.id)
    try
      coordinator.ensure_provider(
        admin,
        provider.name,
        provider_secret,
        ["self-hosted", "linux"],
        [],
        preserve_existing=true,
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("preserve resurrected revoked provider")
    }
  })
}
