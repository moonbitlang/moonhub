///|
async test "provider label replacement changes matching without replacing credentials or grants" {
  with_protocol_fixture((coordinator, pool, _, run, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO pipeline_job_label (job_id, label) SELECT id, 'moonhub-build' FROM pipeline_job WHERE run_id = ?",
          params=[run.id],
        ),
      )
    })
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    coordinator.set_provider_paused(admin, provider.id, true)
    coordinator.set_provider_labels(admin, provider.id, [
      "SELF-HOSTED", "linux", "moonhub-build", "linux",
    ])
    let updated = coordinator.list_providers(admin)[0]
    assert_eq(updated.id, provider.id)
    assert_eq(updated.name, provider.name)
    assert_true(updated.paused)
    assert_false(updated.revoked)
    assert_eq(updated.labels, ["linux", "moonhub-build", "self-hosted"])
    assert_true(coordinator.claim(provider_secret, claim_request()) is None)
    coordinator.set_provider_paused(admin, provider.id, false)
    let assigned = coordinator.claim(provider_secret, claim_request()).unwrap()
    let id = @protocol.parse_decimal(assigned.attempt_id).unwrap()
    ignore(coordinator.start(id, attempt_secret, 1))
    coordinator.set_provider_labels(admin, provider.id, ["self-hosted", "linux"])
    assert_eq(coordinator.list_providers(admin)[0].labels, [
      "linux", "self-hosted",
    ])
    assert_true(coordinator.heartbeat(id, attempt_secret, 1).cancel_requested)
    assert_eq(
      coordinator.complete(
        id,
        attempt_secret,
        completion(conclusion="cancelled"),
      ).conclusion,
      "cancelled",
    )
    coordinator.authenticate_provider(provider_secret)
    assert_eq(
      pool.with_client(client => {
        client
        .query_all(
          "SELECT repository_id FROM pipeline_provider_repository WHERE provider_id = ?",
          params=[provider.id],
        )
        .length()
      }),
      1,
    )
  })
}

///|
async test "removing an unrelated label leaves matching running work unchanged" {
  with_protocol_fixture((coordinator, pool, _, _, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    coordinator.set_provider_labels(admin, provider.id, [
      "self-hosted", "linux", "unused",
    ])
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    ignore(coordinator.start(id, attempt_secret, 1))
    coordinator.set_provider_labels(admin, provider.id, ["self-hosted", "linux"])
    assert_false(coordinator.heartbeat(id, attempt_secret, 1).cancel_requested)
  })
}

///|
async test "label removal cancels leased work and reconciliation releases the provider for queued jobs" {
  with_protocol_fixture((coordinator, pool, root, run, provider, clock) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let actor = @identity.active_user_by_name(pool, "alice")
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO pipeline_job_label (job_id, label) SELECT id, 'moonhub-build' FROM pipeline_job WHERE run_id = ?",
          params=[run.id],
        ),
      )
    })
    let queued = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    coordinator.set_provider_labels(admin, provider.id, [
      "self-hosted", "linux", "moonhub-build",
    ])
    let assigned = coordinator.claim(provider_secret, claim_request()).unwrap()
    assert_eq(assigned.run_id, run.id.to_string())
    let id = @protocol.parse_decimal(assigned.attempt_id).unwrap()
    coordinator.set_provider_labels(admin, provider.id, ["self-hosted", "linux"])
    assert_true(coordinator.start(id, attempt_secret, 1).cancel_requested)
    clock.val += 100L
    coordinator.set_provider_labels(admin, provider.id, [
      "self-hosted", "linux", "moonhub-build",
    ])
    assert_true(coordinator.heartbeat(id, attempt_secret, 1).cancel_requested)
    clock.val += @protocol.cancel_grace_ms
    assert_eq(coordinator.expire_attempts(), 1)
    assert_true(
      get_run(pool, actor, protocol_repo, run.number).conclusion is Some(Lost),
    )
    let next = coordinator
      .claim(provider_secret, claim_request(id="2", secret="c".repeat(64)))
      .unwrap()
    assert_eq(next.run_id, queued.id.to_string())
  })
}

///|
async test "editing one provider does not cancel another provider's running attempt" {
  with_protocol_fixture((coordinator, pool, _, _, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let id = @protocol.parse_decimal(
      coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id,
    ).unwrap()
    ignore(coordinator.start(id, attempt_secret, 1))
    let other = coordinator.create_provider(
      admin,
      "other-labels",
      "d".repeat(64),
      ["self-hosted", "linux", "unused"],
      [protocol_repo],
    )
    coordinator.set_provider_labels(admin, other.id, ["self-hosted", "linux"])
    assert_false(coordinator.heartbeat(id, attempt_secret, 1).cancel_requested)
    assert_eq(coordinator.list_providers(admin)[0].id, provider.id)
  })
}

///|
async test "invalid label replacements leave the complete existing set unchanged" {
  with_protocol_fixture((coordinator, pool, _, _, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    for
      labels in [
        [],
        ["linux"],
        ["self-hosted"],
        ["self-hosted", "linux", ""],
        ["self-hosted", "linux", "bad label"],
        ["self-hosted", "linux", "<script>"],
        ["self-hosted", "linux", "x".repeat(65)],
        ["self-hosted", "linux", "a", "b", "c", "d", "e", "f", "g"],
      ] {
      try coordinator.set_provider_labels(admin, provider.id, labels) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid labels")
      }
      assert_eq(coordinator.list_providers(admin)[0].labels, [
        "linux", "self-hosted",
      ])
    }
    coordinator.set_provider_labels(admin, provider.id, [
      "self-hosted",
      "linux",
      "x".repeat(64),
      "a",
      "b",
      "c",
      "d",
      "e",
    ])
    assert_eq(coordinator.list_providers(admin)[0].labels.length(), 8)
  })
}

///|
async test "provider label edits require a current administrator and a nonrevoked provider" {
  with_protocol_fixture((coordinator, pool, _, _, provider, _) => {
    let admin = @identity.active_user_by_name(pool, "admin")
    let alice = @identity.active_user_by_name(pool, "alice")
    let labels = ["self-hosted", "linux", "moonhub-build"]
    try coordinator.set_provider_labels(alice, provider.id, labels) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("non-admin changed labels")
    }
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE user SET is_site_admin = 0 WHERE id = ?", params=[
          admin.id,
        ]),
      )
    })
    try coordinator.set_provider_labels(admin, provider.id, labels) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale administrator changed labels")
    }
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE user SET is_site_admin = 1 WHERE id = ?", params=[
          admin.id,
        ]),
      )
    })
    coordinator.revoke_provider(admin, provider.id)
    for id in [provider.id, provider.id + 999L] {
      try coordinator.set_provider_labels(admin, id, labels) catch {
        @domain.NotFound(_) => ()
        err => raise err
      } noraise {
        _ => fail("changed revoked or missing provider")
      }
    }
    assert_eq(coordinator.list_providers(admin)[0].labels, [
      "linux", "self-hosted",
    ])
  })
}
