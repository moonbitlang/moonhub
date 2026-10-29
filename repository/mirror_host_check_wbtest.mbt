///|
async test "host initialization binds confirmation to its scanned key saved address version and expiry" {
  mirror_fixture((pool, root, actor, repo, config, _) => {
    let scanner = root + "/keyscan"
    let key = @test_support.test_ssh_public_key
    @fs.write_file(
      scanner,
      "#!/bin/sh\nprintf '%s\\n' 'source.example \{key}'\n",
      permission=0o700,
    )
    let config = { ..config, keyscan_command: scanner, }
    let id = save_push_mirror(
      pool, root, actor, repo, 0L, 0L, "git@source.example:org/demo.git", false,
      false, false,
    )
    initialize_mirror_host(pool, root, actor, repo, id, 1L, config)
    let pending = push_mirrors(pool, actor, repo)[0]
    let first = pending.host_check.unwrap()
    assert_true(pending.host_keys.is_empty())
    assert_eq(first.fingerprints, [
      "SHA256:RXm/ruZ0eTzRXKwi1AQEDynB0VgHQ2ac9KPSFdf/YnA",
    ])
    // Reinitializing replaces the challenge, so another tab cannot trust an unseen result.
    initialize_mirror_host(pool, root, actor, repo, id, 1L, config)
    try
      confirm_mirror_host(pool, root, actor, repo, id, 1L, first.challenge)
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("confirmed superseded scan")
    }
    let second = push_mirrors(pool, actor, repo)[0].host_check.unwrap()
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE mirror_host_check SET created_at=datetime('now','-11 minutes')",
        ),
      )
    })
    assert_true(push_mirrors(pool, actor, repo)[0].host_check is None)
    try
      confirm_mirror_host(pool, root, actor, repo, id, 1L, second.challenge)
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("confirmed expired scan")
    }
    initialize_mirror_host(pool, root, actor, repo, id, 1L, config)
    let third = push_mirrors(pool, actor, repo)[0].host_check.unwrap()
    confirm_mirror_host(pool, root, actor, repo, id, 1L, third.challenge)
    assert_eq(push_mirrors(pool, actor, repo)[0].host_keys, key)
    assert_false(push_mirrors(pool, actor, repo)[0].active)
    // Changing a port discards trust even if the DNS name is unchanged.
    ignore(
      save_push_mirror(
        pool, root, actor, repo, id, 2L, "ssh://git@source.example:2222/org/demo.git",
        false, false, false,
      ),
    )
    assert_true(push_mirrors(pool, actor, repo)[0].host_keys.is_empty())
    try
      confirm_mirror_host(pool, root, actor, repo, id, 3L, third.challenge)
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("reused trust for a changed endpoint")
    }
    @fs.write_file(
      scanner,
      "#!/bin/sh\nprintf '%s\\n' '[source.example]:2222 \{key}'\n",
      permission=0o700,
    )
    initialize_mirror_host(pool, root, actor, repo, id, 3L, config)
    let fourth = push_mirrors(pool, actor, repo)[0].host_check.unwrap()
    ignore(
      save_push_mirror(
        pool, root, actor, repo, id, 3L, "git@different.example:org/demo.git", false,
        false, false,
      ),
    )
    try
      confirm_mirror_host(pool, root, actor, repo, id, 4L, fourth.challenge)
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("confirmed a scan for another saved address")
    }
    for
      output in [
        "different.example ssh-ed25519 invalid",
        "wrong.example " + key,
        "",
      ] {
      @fs.write_file(
        scanner,
        "#!/bin/sh\nprintf '%s\\n' '\{output}'\n",
        permission=0o700,
      )
      try
        initialize_mirror_host(pool, root, actor, repo, id, 4L, config)
      catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid scanner output")
      }
      assert_true(push_mirrors(pool, actor, repo)[0].host_check is None)
    }
  })
}
