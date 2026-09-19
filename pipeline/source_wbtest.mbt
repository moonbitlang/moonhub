///|
async test "checkout requires a live authorized attempt and denies stale source credentials" {
  for
    reason in [
      "leased", "expired", "completed", "cancelled", "revoked", "grant", "actor",
    ] {
    with_protocol_fixture((coordinator, pool, root, run, provider, clock) => {
      let id = coordinator.claim(provider_secret, claim_request()).unwrap().attempt_id
      if reason != "leased" {
        ignore(coordinator.start(id, attempt_secret, 1))
        let archive = coordinator.read_source(root, id, attempt_secret)
        assert_true(archive.length() > 1024)
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
  }
}
