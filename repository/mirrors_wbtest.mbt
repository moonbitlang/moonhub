///|
// Preconfirmed trust is fixture data for transfer and concurrency tests.
// Production saves cannot accept host keys; managers must initialize and confirm.
async fn save_fixture_mirror(
  pool : @database.Database,
  root : String,
  actor : @domain.CurrentUser,
  repo : @domain.RepoId,
  id : Int64,
  version : Int64,
  url : String,
  active : Bool,
  force_push : Bool,
  prune : Bool,
  host_keys~ : String = "",
) -> Int64 {
  if id != 0L || host_keys.is_empty() {
    return save_push_mirror(
      pool, root, actor, repo, id, version, url, active, force_push, prune,
    )
  }
  let id = save_push_mirror(
    pool, root, actor, repo, id, version, url, false, force_push, prune,
  )
  pool.with_client(client => {
    ignore(
      client.execute(
        "UPDATE repository_mirror SET host_keys=?,active=?,status=? WHERE id=?",
        params=[
          host_keys,
          active,
          if active {
            "pending"
          } else {
            "disabled"
          },
          id,
        ],
      ),
    )
  })
  id
}

///|
async fn mirror_fixture(
  f : async (
    @database.Database,
    String,
    @domain.CurrentUser,
    @domain.RepoId,
    MirrorConfig,
    String,
  ) -> Unit,
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let remote = root + "/remote.git"
    ignore(
      @gitops.merge_git(root + "/alice/demo.git", ["init", "--bare", remote]),
    )
    ignore(
      @gitops.merge_git(remote, [
        "config", "receive.denyDeleteCurrent", "ignore",
      ]),
    )
    let wrapper = root + "/mirror-ssh"
    let config : MirrorConfig = {
      ..default_mirror_config,
      ssh_command: wrapper,
    }
    @fs.write_file(
      config.ssh_command,
      "#!/bin/sh\nexec git receive-pack '\{remote}'\n",
      permission=0o700,
    )
    f(
      pool,
      root,
      @identity.active_user_by_name(pool, "alice"),
      { owner: "alice", name: "demo", },
      config,
      remote,
    )
  })
}

///|
async fn mirror_refs(dir : String) -> String {
  @gitops.merge_git(dir, [
    "for-each-ref", "--format=%(refname) %(objectname)", "refs/heads/", "refs/tags/",
  ])
}

///|
async test "push mirrors copy branches and annotated tags without private refs, enforce force and prune policies" {
  mirror_fixture((pool, root, actor, repo, config, remote) => {
    let dir = repo.git_dir(root)
    let parent = @gitops.branch_sha(dir, "master")
    let tree = @gitops.merge_git(dir, ["rev-parse", "master^{tree}"])
      .trim()
      .to_owned()
    let sha = @gitops.merge_git(dir, [
        "commit-tree", tree, "-p", parent, "-m", "Ahead commit",
      ])
      .trim()
      .to_owned()
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", sha]))
    ignore(@gitops.merge_git(dir, ["tag", "-a", "v1", "-m", "release", sha]))
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/moonhub/secret", sha]))
    let id = save_fixture_mirror(
      pool,
      root,
      actor,
      repo,
      0L,
      0L,
      "git@source.example:org/demo.git",
      true,
      false,
      false,
      host_keys=@test_support.test_ssh_public_key,
    )
    assert_true(sync_next_mirror(pool, root, config))
    assert_eq(push_mirrors(pool, actor, repo)[0].status, "succeeded")
    assert_eq(mirror_refs(dir), mirror_refs(remote))
    assert_eq(@gitops.merge_git(remote, ["for-each-ref", "refs/moonhub/"]), "")
    // Rewind the source branch to exercise a rejected non-fast-forward.
    let previous = @gitops.merge_git(dir, ["rev-parse", "master^"])
      .trim()
      .to_owned()
    ignore(
      @gitops.merge_git(dir, ["update-ref", "refs/heads/master", previous]),
    )
    push_mirror_action(pool, root, actor, repo, id, 1L, "sync")
    assert_true(sync_next_mirror(pool, root, config))
    let failed = push_mirrors(pool, actor, repo)[0]
    assert_eq(failed.status, "pending")
    assert_eq(failed.attempts, 1L)
    assert_false(failed.error.is_empty())
    assert_eq(@gitops.branch_sha(remote, "master"), sha)
    assert_false(failed.error.contains(remote))
    ignore(
      @gitops.merge_git(remote, ["update-ref", "refs/heads/remote-only", sha]),
    )
    ignore(
      @gitops.merge_git(remote, ["update-ref", "refs/tags/remote-only", sha]),
    )
    ignore(
      save_fixture_mirror(
        pool,
        root,
        actor,
        repo,
        id,
        2L,
        failed.url,
        true,
        true,
        false,
        host_keys=@test_support.test_ssh_public_key,
      ),
    )
    assert_true(sync_next_mirror(pool, root, config))
    assert_eq(@gitops.branch_sha(remote, "master"), previous)
    assert_true(mirror_refs(remote).contains("remote-only"))
    ignore(
      save_fixture_mirror(
        pool,
        root,
        actor,
        repo,
        id,
        3L,
        failed.url,
        true,
        true,
        true,
        host_keys=@test_support.test_ssh_public_key,
      ),
    )
    assert_true(sync_next_mirror(pool, root, config))
    assert_eq(mirror_refs(dir), mirror_refs(remote))
    assert_eq(mirror_history(pool, actor, repo, id).length(), 4)
    push_mirror_action(pool, root, actor, repo, id, 4L, "delete")
    assert_true(push_mirrors(pool, actor, repo).is_empty())
  })
}

///|
async test "mirror intents capture committed branch and tag deletions, recover interruptions and ignore aborts" {
  mirror_fixture((pool, root, actor, repo, config, remote) => {
    let id = save_fixture_mirror(
      pool,
      root,
      actor,
      repo,
      0L,
      0L,
      "git@source.example:org/demo.git",
      true,
      false,
      true,
      host_keys=@test_support.test_ssh_public_key,
    )
    assert_true(sync_next_mirror(pool, root, config))
    let dir = repo.git_dir(root)
    let sha = @gitops.branch_sha(dir, "master")
    let zero = "0".repeat(40)
    let key = "a".repeat(32)
    let line = "\{zero} \{sha} refs/tags/received"
    record_received_transaction(pool, actor, repo, key, "prepared", line)
    assert_false(sync_next_mirror(pool, root, config))
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/tags/received", sha]))
    // Simulate a lost committed hook: recovery inspects actual refs under the write lock.
    ignore(recover_mirror_repositories(pool, root, 0L))
    assert_true(sync_next_mirror(pool, root, config))
    assert_true(mirror_refs(remote).contains("refs/tags/received"))
    let deleted = "\{sha} \{zero} refs/tags/received"
    record_received_transaction(
      pool,
      actor,
      repo,
      "b".repeat(32),
      "prepared",
      deleted,
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "-d", "refs/tags/received"]))
    record_received_transaction(
      pool,
      actor,
      repo,
      "b".repeat(32),
      "committed",
      deleted,
    )
    assert_true(sync_next_mirror(pool, root, config))
    assert_false(mirror_refs(remote).contains("refs/tags/received"))
    record_received_transaction(
      pool,
      actor,
      repo,
      "c".repeat(32),
      "prepared",
      line,
    )
    record_received_transaction(
      pool,
      actor,
      repo,
      "c".repeat(32),
      "aborted",
      line,
    )
    assert_false(sync_next_mirror(pool, root, config))
    assert_true(list_ref_events(pool, actor, repo).is_empty())
    assert_eq(mirror_history(pool, actor, repo, id).length(), 3)
  })
}

///|
async test "mirror configuration requires manager, validates hosts and versions, disables and rechecks revoked access" {
  mirror_fixture((pool, root, actor, repo, config, _) => {
    let id = save_fixture_mirror(
      pool,
      root,
      actor,
      repo,
      0L,
      0L,
      "git@source.example:org/demo.git",
      true,
      false,
      false,
      host_keys=@test_support.test_ssh_public_key,
    )
    for
      url in [
        "https://github.com/org/repo.git", "git@source.example:../repo.git", "ext::sh -c bad",
      ] {
      try
        save_fixture_mirror(
          pool,
          root,
          actor,
          repo,
          0L,
          0L,
          url,
          true,
          false,
          false,
          host_keys=@test_support.test_ssh_public_key,
        )
      catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted unsafe mirror destination")
      }
    }
    try
      save_fixture_mirror(
        pool,
        root,
        actor,
        repo,
        id,
        2L,
        "git@source.example:org/demo.git",
        false,
        false,
        false,
        host_keys=@test_support.test_ssh_public_key,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted stale version")
    }
    ignore(
      save_fixture_mirror(
        pool,
        root,
        actor,
        repo,
        id,
        1L,
        "git@source.example:org/demo.git",
        false,
        false,
        false,
        host_keys=@test_support.test_ssh_public_key,
      ),
    )
    assert_false(sync_next_mirror(pool, root, config))
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id,user_id,role) VALUES(1,2,'member')",
        ),
      )
    })
    let contributor = @identity.active_user_by_name(pool, "bob")
    try push_mirrors(pool, contributor, repo) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("member inspected mirror configuration")
    }
    ignore(
      save_fixture_mirror(
        pool,
        root,
        actor,
        repo,
        id,
        2L,
        "git@source.example:org/demo.git",
        true,
        false,
        false,
        host_keys=@test_support.test_ssh_public_key,
      ),
    )
    pool.with_client(client => {
      ignore(
        client.execute("DELETE FROM team_member WHERE team_id=1 AND user_id=1"),
      )
    })
    assert_true(sync_next_mirror(pool, root, config))
    let admin = @identity.active_user_by_name(pool, "admin")
    assert_eq(push_mirrors(pool, admin, repo)[0].status, "failed")
    assert_eq(mirror_history(pool, admin, repo, id).length(), 0)
  })
}

///|
async test "empty source prunes final refs and failed workers exhaust retry budgets" {
  mirror_fixture((pool, root, actor, repo, config, remote) => {
    let id = save_fixture_mirror(
      pool,
      root,
      actor,
      repo,
      0L,
      0L,
      "git@source.example:org/demo.git",
      true,
      false,
      true,
      host_keys=@test_support.test_ssh_public_key,
    )
    assert_true(sync_next_mirror(pool, root, config))
    ignore(
      @gitops.merge_git(repo.git_dir(root), [
        "update-ref", "-d", "refs/heads/master",
      ]),
    )
    push_mirror_action(pool, root, actor, repo, id, 1L, "sync")
    assert_true(sync_next_mirror(pool, root, config))
    assert_eq(mirror_refs(remote), "")
    @fs.write_file(
      config.ssh_command,
      "#!/bin/sh\nprintf 'sensitive diagnostic' >&2\nexit 1\n",
      permission=0o700,
    )
    push_mirror_action(pool, root, actor, repo, id, 2L, "sync")
    for _ in 0..<5 {
      pool.with_client(client => {
        ignore(
          client.execute(
            "UPDATE repository_mirror SET next_attempt_at=datetime('now','-1 minute') WHERE id=?",
            params=[id],
          ),
        )
      })
      assert_true(sync_next_mirror(pool, root, config))
    }
    assert_eq(push_mirrors(pool, actor, repo)[0].status, "failed")
    assert_eq(push_mirrors(pool, actor, repo)[0].attempts, 5L)
    assert_false(sync_next_mirror(pool, root, config))
    assert_false(
      mirror_history(pool, actor, repo, id)[0].error.contains("sensitive"),
    )
    push_mirror_action(pool, root, actor, repo, id, 3L, "sync")
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE repository_mirror SET status='syncing',lease='lost',locked_at=datetime('now','-3 hours'),attempts=1 WHERE id=?",
          params=[id],
        ),
      )
      ignore(
        client.execute(
          "INSERT INTO mirror_attempt(mirror_id,generation,status) VALUES(?,1,'syncing')",
          params=[id],
        ),
      )
    })
    assert_true(sync_next_mirror(pool, root, config))
    assert_eq(push_mirrors(pool, actor, repo)[0].attempts, 2L)
    assert_false(
      mirror_history(pool, actor, repo, id).any(attempt => {
        attempt.status == "syncing"
      }),
    )
  })
}

///|
async test "updates arriving during a mirror transfer stay queued and source writes remain available" {
  mirror_fixture((pool, root, actor, repo, config, remote) => {
    let id = save_fixture_mirror(
      pool,
      root,
      actor,
      repo,
      0L,
      0L,
      "git@source.example:org/demo.git",
      true,
      false,
      false,
      host_keys=@test_support.test_ssh_public_key,
    )
    let marker = root + "/transfer-started"
    let release = root + "/transfer-release"
    @fs.write_file(
      config.ssh_command,
      "#!/bin/sh\ntouch '\{marker}'\nwhile [ ! -f '\{release}' ]; do sleep 0.05; done\nexec git receive-pack '\{remote}'\n",
      permission=0o700,
    )
    @async.with_task_group(group => {
      let transfer = group.spawn(() => sync_next_mirror(pool, root, config))
      @async.with_timeout(10000, () => {
        while !@fs.exists(marker) {
          @async.sleep(20)
        }
      })
      let sha = @gitops.branch_sha(repo.git_dir(root), "master")
      // Acquiring this lock while SSH is stalled proves the network does not hold it.
      with_repository_write(pool, root, actor, repo, (_, dir) => {
        let line = "\{"0".repeat(40)} \{sha} refs/heads/during-transfer"
        record_received_transaction(
          pool,
          actor,
          repo,
          "d".repeat(32),
          "prepared",
          line,
        )
        ignore(
          @gitops.merge_git(dir, [
            "update-ref", "refs/heads/during-transfer", sha,
          ]),
        )
        record_received_transaction(
          pool,
          actor,
          repo,
          "d".repeat(32),
          "committed",
          line,
        )
      })
      @fs.write_file(release, "")
      assert_true(transfer.wait())
    })
    assert_eq(push_mirrors(pool, actor, repo)[0].status, "pending")
    assert_false(mirror_refs(remote).contains("during-transfer"))
    assert_true(sync_next_mirror(pool, root, config))
    assert_eq(push_mirrors(pool, actor, repo)[0].status, "succeeded")
    assert_true(mirror_refs(remote).contains("during-transfer"))
    assert_eq(mirror_history(pool, actor, repo, id).length(), 2)
  })
}

///|
async test "mirror keys are independent durable rotated with versions and cleaned after transfers" {
  mirror_fixture((pool, root, actor, repo, config, _) => {
    // No SSH import directories or configuration exist in this fixture.
    let first = save_fixture_mirror(
      pool,
      root,
      actor,
      repo,
      0L,
      0L,
      "git@source.example:org/first.git",
      true,
      false,
      false,
      host_keys=@test_support.test_ssh_public_key,
    )
    let second = save_fixture_mirror(
      pool,
      root,
      actor,
      repo,
      0L,
      0L,
      "git@source.example:org/second.git",
      false,
      false,
      false,
      host_keys=@test_support.test_ssh_public_key,
    )
    let mirrors = push_mirrors(pool, actor, repo)
    let public_key = mirrors[0].public_key
    assert_true(public_key.has_prefix("ssh-ed25519 "))
    assert_false(public_key == mirrors[1].public_key)
    let path = root + "/last-identity-path"
    let expected = root + "/expected-public-key"
    @fs.write_file(expected, public_key.split(" ").take(2).join(" "))
    @fs.write_file(
      config.ssh_command,
      "#!/bin/sh\nset -eu\nactual=$(/usr/bin/ssh-keygen -y -f \"$MOONHUB_MIRROR_IDENTITY\" | cut -d ' ' -f 1-2)\ntest \"$actual\" = \"$(cat '\{expected}')\"\nprintf '%s' \"$MOONHUB_MIRROR_IDENTITY\" > '\{path}'\nexec git receive-pack '\{root}/remote.git'\n",
      permission=0o700,
    )
    assert_true(sync_next_mirror(pool, root, config))
    assert_eq(push_mirrors(pool, actor, repo)[0].status, "succeeded")
    assert_false(@fs.exists(@fs.read_file(path).text()))
    assert_false(
      @fs.readdir(root + "/.mirrors").any(name => name.has_prefix("key-")),
    )
    // The same cleanup must run when the SSH process fails.
    @fs.write_file(
      config.ssh_command,
      "#!/bin/sh\nprintf '%s' \"$MOONHUB_MIRROR_IDENTITY\" > '\{path}'\nexit 1\n",
      permission=0o700,
    )
    push_mirror_action(pool, root, actor, repo, first, 1L, "sync")
    assert_true(sync_next_mirror(pool, root, config))
    assert_false(@fs.exists(@fs.read_file(path).text()))
    ignore(
      save_fixture_mirror(
        pool,
        root,
        actor,
        repo,
        first,
        2L,
        "git@source.example:org/first.git",
        true,
        false,
        false,
        host_keys=@test_support.test_ssh_public_key,
      ),
    )
    assert_eq(push_mirrors(pool, actor, repo)[0].public_key, public_key)
    rotate_mirror_key(pool, root, actor, repo, first, 3L)
    let rotated = push_mirrors(pool, actor, repo)
    assert_false(rotated[0].public_key == public_key)
    assert_eq(rotated[0].status, "disabled")
    assert_false(rotated[0].active)
    assert_eq(rotated[1].public_key, mirrors[1].public_key)
    assert_eq(rotated[0].version, 4L)
    try rotate_mirror_key(pool, root, actor, repo, first, 2L) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("rotated a stale mirror key")
    }
    let other : @domain.RepoId = { owner: "alice", name: "public", }
    try rotate_mirror_key(pool, root, actor, other, first, 4L) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("rotated another repository's key")
    }
    push_mirror_action(pool, root, actor, repo, first, 4L, "delete")
    pool.with_client(client => {
      assert_true(
        client.query_opt(
          "SELECT mirror_id FROM mirror_ssh_key WHERE mirror_id=?",
          params=[first],
        )
        is None,
      )
      assert_true(
        client.query_opt(
          "SELECT mirror_id FROM mirror_ssh_key WHERE mirror_id=?",
          params=[second],
        )
        is Some(_),
      )
    })
  })
}

///|
test "mirror host keys validate encoding and pin only the selected destination" {
  let key = @test_support.test_ssh_public_key
  assert_eq(normalize_mirror_host_keys(key + "\n" + key + " comment"), key)
  assert_eq(normalize_mirror_host_keys("\n\n"), "")
  assert_eq(
    mirror_known_hosts(
      parse_ssh_import_source("git@source.example:org/demo.git"),
      key,
    ),
    "source.example " + key + "\n",
  )
  assert_eq(
    mirror_known_hosts(
      parse_ssh_import_source("ssh://git@source.example:2222/org/demo.git"),
      key,
    ),
    "[source.example]:2222 " + key + "\n",
  )
  for
    line in [
      "*.example " + key,
      "@cert-authority " + key,
      "source.example " + key,
      "ssh-ed25519 invalid",
      "ssh-ed25519 AAAA",
      "ssh-rsa AAAA",
      "ssh-ed25519 AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    ] {
    try normalize_mirror_host_keys(line) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid host key")
    }
  }
  try
    mirror_known_hosts(
      parse_ssh_import_source("git@source.example:org/demo.git"),
      "",
    )
  catch {
    @domain.BadRequest(_) => ()
    err => raise err
  } noraise {
    _ => fail("enabled a mirror without host trust")
  }
}

///|
async test "mirror trust is scoped versioned and temporary host files are cleaned" {
  mirror_fixture((pool, root, actor, repo, config, remote) => {
    let key = @test_support.test_ssh_public_key
    let id = save_fixture_mirror(
      pool,
      root,
      actor,
      repo,
      0L,
      0L,
      "git@source.example:org/demo.git",
      true,
      false,
      false,
      host_keys=key,
    )
    try
      save_fixture_mirror(
        pool, root, actor, repo, 0L, 0L, "git@source.example:org/other.git", true,
        false, false,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("another mirror inherited destination trust")
    }
    let observed = root + "/host-path"
    let expected = root + "/expected-hosts"
    @fs.write_file(expected, "source.example " + key + "\n")
    @fs.write_file(
      config.ssh_command,
      "#!/bin/sh\nset -eu\ntest -f \"$MOONHUB_MIRROR_IDENTITY\"\ncat \"$MOONHUB_MIRROR_KNOWN_HOSTS\" | cmp - '\{expected}'\nprintf '%s' \"$MOONHUB_MIRROR_KNOWN_HOSTS\" > '\{observed}'\nexec git receive-pack '\{remote}'\n",
      permission=0o700,
    )
    assert_true(sync_next_mirror(pool, root, config))
    assert_eq(push_mirrors(pool, actor, repo)[0].status, "succeeded")
    assert_false(@fs.exists(@fs.read_file(observed).text()))
    ignore(
      save_fixture_mirror(
        pool, root, actor, repo, id, 1L, "git@source.example:org/demo.git", false,
        false, false,
      ),
    )
    assert_eq(push_mirrors(pool, actor, repo)[0].host_keys, key)
    assert_false(sync_next_mirror(pool, root, config))
    try
      save_fixture_mirror(
        pool,
        root,
        actor,
        repo,
        id,
        1L,
        "git@source.example:org/demo.git",
        true,
        false,
        false,
        host_keys=key,
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("overwrote newer trust configuration")
    }
    assert_false(@fs.exists(root + "/credentials"))
  })
}
