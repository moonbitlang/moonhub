///|
async test "own-instance imports require source read permission on public and internal addresses" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    for
      url in [
        "ssh://git@git.example.com:12222/alice/demo.git", "ssh://git@ssh:2222/alice/demo.git",
      ] {
      let source = @repository.resolve_repository_import_source(
        pool, alice, url, @web_testkit.test_ssh_addresses,
      )
      assert_true(source.local_id is Some(1L))
      assert_eq(source.transport.url, "ssh://git@ssh:2222/alice/demo.git")
      try
        @repository.resolve_repository_import_source(
          pool, bob, url, @web_testkit.test_ssh_addresses,
        )
      catch {
        @domain.NotFound(_) => ()
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("private source accessible to another user")
      }
    }
    let public_source = @repository.resolve_repository_import_source(
      pool, bob, "ssh://git@git.example.com:12222/alice/public.git", @web_testkit.test_ssh_addresses,
    )
    assert_true(public_source.local_id is Some(2L))
    for
      url in [
        "ssh://git@git.example.com:22/alice/demo.git", "ssh://git@git.example.com.other:12222/alice/demo.git",
      ] {
      let external = @repository.resolve_repository_import_source(
        pool, bob, url, @web_testkit.test_ssh_addresses,
      )
      assert_true(external.local_id is None)
      assert_eq(external.transport.url, url)
    }
  })
}

///|
async test "queued local imports keep source identity across public address changes" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
    let addresses : @repository.SshAddressConfig = {
      public_override: None,
      internal: @web_testkit.test_ssh_addresses.internal,
    }
    @repository.save_ssh_endpoint(
      pool, admin, addresses, "git.example.com", "12222",
    )
    ignore(
      @repository.enqueue_repository(
        pool,
        root,
        alice,
        team,
        "local-copy",
        "private",
        "ssh://git@git.example.com:12222/alice/demo.git",
        addresses~,
      ),
    )
    let job = @repository.require_repository_job(pool, team, "local-copy")
    assert_eq(job.source_kind, "local")
    assert_true(job.source_repository_id is Some(1L))
    @repository.save_ssh_endpoint(
      pool, admin, addresses, "changed.example", "22",
    )
    assert_eq(
      @repository.repository_job_source(pool, alice, job, addresses).unwrap().url,
      "ssh://git@ssh:2222/alice/demo.git",
    )
    let config = @test_support.mock_import_config(
      root,
      "\{root}/alice/demo.git",
    )
    @fs.write_file(
      "\{config.credentials_root}/alice/allowed_hosts",
      "ssh:2222\n",
      permission=0o600,
    )
    assert_true(
      @repository.run_next_repository_job(pool, root, Some(config), addresses~),
    )
    assert_eq(
      @repository.require_repository_job(pool, team, "local-copy").status,
      "succeeded",
    )
    assert_true(
      @repository.can_access_repository(
        pool,
        alice,
        { owner: "alice", name: "local-copy", },
        @repository.Read,
      ),
    )
  })
}

///|
async test "local import fails closed after source deletion even if its path is reused" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
    ignore(
      @repository.enqueue_repository(
        pool,
        root,
        alice,
        team,
        "deleted-copy",
        "private",
        "ssh://git@git.example.com:12222/alice/demo.git",
        addresses=@web_testkit.test_ssh_addresses,
      ),
    )
    pool.with_client(client => {
      client.batch_execute(
        "DELETE FROM repository WHERE id = 1; INSERT INTO repository (team_id, name, visibility) VALUES (1, 'demo', 'private');",
      )
    })
    let job = @repository.require_repository_job(pool, team, "deleted-copy")
    assert_eq(job.source_kind, "local")
    assert_true(job.source_repository_id is None)
    assert_true(
      @repository.run_next_repository_job(
        pool,
        root,
        None,
        addresses=@web_testkit.test_ssh_addresses,
      ),
    )
    assert_eq(
      @repository.require_repository_job(pool, team, "deleted-copy").status,
      "failed",
    )
    assert_true(!@fs.exists("\{root}/alice/deleted-copy.git"))
  })
}

///|
async test "source permission revocation blocks queued local import" {
  @test_support.with_repository_test_data((pool, root) => {
    let bob = @identity.active_user_by_name(pool, "bob")
    let team = @identity.get_team_by_name_key(pool, "bob").unwrap()
    ignore(
      @repository.enqueue_repository(
        pool,
        root,
        bob,
        team,
        "revoked-copy",
        "private",
        "ssh://git@git.example.com:12222/alice/public.git",
        addresses=@web_testkit.test_ssh_addresses,
      ),
    )
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository SET visibility = 'private' WHERE id = 2",
      )
    })
    assert_true(
      @repository.run_next_repository_job(
        pool,
        root,
        None,
        addresses=@web_testkit.test_ssh_addresses,
      ),
    )
    assert_eq(
      @repository.require_repository_job(pool, team, "revoked-copy").status,
      "failed",
    )
    assert_true(!@fs.exists("\{root}/bob/revoked-copy.git"))
  })
}

///|
async test "external jobs stay external while legacy jobs are checked and pinned" {
  @test_support.with_repository_test_data((pool, root) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let team = @identity.get_team_by_name_key(pool, "alice").unwrap()
    let url = "ssh://git@git.example.com:12222/alice/demo.git"
    ignore(
      @repository.enqueue_repository(
        pool, root, alice, team, "external-copy", "private", url,
      ),
    )
    let external = @repository.require_repository_job(
      pool, team, "external-copy",
    )
    assert_eq(external.source_kind, "external")
    assert_eq(
      @repository.repository_job_source(
        pool, alice, external, @web_testkit.test_ssh_addresses,
      ).unwrap().url,
      url,
    )
    pool.with_client(client => {
      let _ = client.execute(
        "UPDATE repository_job SET source_kind = 'legacy' WHERE repository_id = ?",
        params=[external.id],
      )
    })
    let legacy = @repository.require_repository_job(pool, team, "external-copy")
    let pinned = @repository.pin_legacy_repository_source(
      pool, alice, legacy, @web_testkit.test_ssh_addresses,
    )
    assert_eq(pinned.source_kind, "local")
    assert_true(pinned.source_repository_id is Some(1L))
    assert_eq(
      @repository.require_repository_job(pool, team, "external-copy").source_kind,
      "local",
    )
    assert_eq(
      @repository.repository_job_source(
        pool, alice, pinned, @web_testkit.test_ssh_addresses,
      ).unwrap().url,
      "ssh://git@ssh:2222/alice/demo.git",
    )
  })
}
