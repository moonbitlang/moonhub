///|
fn reject_deploy_operation(f : () -> Unit raise) -> Unit raise {
  try f() catch {
    @domain.BadRequest(_)
    | @domain.NotFound(_)
    | @domain.Forbidden(_)
    | @domain.Unauthorized(_) => ()
    err => raise err
  } noraise {
    _ => fail("unauthorized deploy key operation succeeded")
  }
}

///|
fn deploy_test_key(byte : Byte) -> SshPublicKey raise {
  parse_ssh_public_key(
    "ssh-ed25519 " +
    @base64.encode(
      b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20" + Bytes::make(32, byte),
    ),
  )
}

///|
async test "deploy identity is repository scoped and read-only until explicitly changed" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let key = deploy_test_key(b'\x01')
    let id = add_repository_deploy_key(pool, alice, repo, "Production", key)
    let credential = SshCredential::parse("deploy:\{id}")
    assert_true(credential is DeployKey(_))
    assert_true(SshCredential::parse(id.to_string()) is UserKey(_))
    assert_eq(
      authorized_ssh_key(pool, key),
      Some(
        "restrict,command=\"/usr/local/bin/moonhub ssh-serve deploy:\{id}\" \{key.public_key}",
      ),
    )
    let scope = authorize_git_operation(
      pool,
      credential,
      repo,
      @repository.Read,
    )
    assert_eq(scope.repo.path(), "alice/demo")
    reject_deploy_operation(() => {
      ignore(authorize_git_operation(pool, credential, repo, @repository.Write))
    })
    reject_deploy_operation(() => ignore(ssh_key_user(pool, id)))
    for path in ["alice/public", "bob/demo", "alice/missing"] {
      for operation in [@repository.Read, @repository.Write] {
        reject_deploy_operation(() => {
          ignore(
            authorize_git_operation(
              pool,
              credential,
              @domain.parse_transport_repo(path),
              operation,
            ),
          )
        })
      }
    }
    set_repository_deploy_key_access(pool, alice, repo, id, true)
    ignore(authorize_git_operation(pool, credential, repo, @repository.Write))
    let sha = "a".repeat(40)
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO branch_rule (repository_id, branch) VALUES (?, 'main')",
          params=[scope.id],
        ),
      )
    })
    @collaboration.check_received_ref_rules(
      pool,
      scope,
      "\{sha} \{sha} refs/heads/topic\n",
    )
    for
      reference in ["refs/heads/main", "refs/moonhub/pipelines/attack", "HEAD"] {
      reject_deploy_operation(() => {
        @collaboration.check_received_ref_rules(
          pool,
          scope,
          "\{sha} \{sha} \{reference}\n",
        )
      })
    }
    set_repository_deploy_key_access(pool, alice, repo, id, false)
    reject_deploy_operation(() => {
      ignore(authorize_git_operation(pool, credential, repo, @repository.Write))
    })
    let keys = repository_deploy_keys(pool, alice, repo)
    assert_eq(keys.length(), 1)
    assert_false(keys[0].write_access)
    assert_eq(keys[0].creator, "alice")
    assert_true(keys[0].last_used_at is None)
    assert_false(keys[0].created_at.is_empty())
    revoke_repository_deploy_key(pool, alice, repo, id)
    assert_true(authorized_ssh_key(pool, key) is None)
    reject_deploy_operation(() => {
      ignore(authorize_git_operation(pool, credential, repo, @repository.Read))
    })
    reject_deploy_operation(() => {
      set_repository_deploy_key_access(pool, alice, repo, id, true)
    })
    reject_deploy_operation(() => {
      revoke_repository_deploy_key(pool, alice, repo, id)
    })
    pool.with_client(client => {
      let audit = client.query_all(
        "SELECT kind, actor_id FROM repository_audit WHERE repository_id = ? ORDER BY id",
        params=[scope.id],
      )
      assert_eq(audit.map(row => (row.get_name("kind") : String)), [
        "deploy_key_added", "deploy_key_access_changed", "deploy_key_access_changed",
        "deploy_key_revoked",
      ])
      assert_true(
        audit.all(row => (row.get_name("actor_id") : Int64) == alice.id),
      )
    })
  })
}

///|
async test "duplicates reuse and user-key collisions remain denied after revocation or deletion" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let other : @domain.RepoId = { owner: "alice", name: "public", }
    let user_key = deploy_test_key(b'\x01')
    let user_id = add_ssh_key(pool, alice, "User key", user_key)
    reject_deploy_operation(() => {
      ignore(
        add_repository_deploy_key(pool, alice, repo, "Collision", user_key),
      )
    })
    revoke_own_ssh_key(pool, alice, user_id)
    reject_deploy_operation(() => {
      ignore(
        add_repository_deploy_key(pool, alice, repo, "Revoked user", user_key),
      )
    })
    let key = deploy_test_key(b'\x02')
    let id = add_repository_deploy_key(pool, alice, repo, "Deploy", key)
    for target in [repo, other] {
      reject_deploy_operation(() => {
        ignore(
          add_repository_deploy_key(
            pool,
            alice,
            target,
            "Duplicate",
            parse_ssh_public_key(key.public_key + " different-comment"),
          ),
        )
      })
    }
    reject_deploy_operation(() => {
      ignore(add_ssh_key(pool, alice, "Collision", key))
    })
    revoke_repository_deploy_key(pool, alice, repo, id)
    reject_deploy_operation(() => {
      ignore(add_repository_deploy_key(pool, alice, other, "Reuse", key))
    })
    reject_deploy_operation(() => {
      ignore(add_ssh_key(pool, alice, "Revoked deploy", key))
    })
    let deleted_key = deploy_test_key(b'\x03')
    let deleted_id = add_repository_deploy_key(
      pool, alice, repo, "Deleted", deleted_key,
    )
    let other_key = deploy_test_key(b'\x04')
    let other_id = add_repository_deploy_key(
      pool, alice, other, "Unaffected", other_key,
    )
    pool.with_client(client => {
      ignore(client.execute("DELETE FROM repository WHERE name = 'demo'"))
      ignore(
        client.execute(
          "INSERT INTO repository (team_id, name) VALUES (1, 'demo')",
        ),
      )
      let row = client.query_one(
        "SELECT repository_id, revoked_at FROM repository_deploy_key WHERE id = ?",
        params=[deleted_id],
      )
      assert_true((row.get_name("repository_id") : Int64?) is None)
      assert_true((row.get_name("revoked_at") : String?) is Some(_))
    })
    assert_true(authorized_ssh_key(pool, deleted_key) is None)
    reject_deploy_operation(() => {
      ignore(
        authorize_git_operation(
          pool,
          DeployKey(deleted_id),
          repo,
          @repository.Read,
        ),
      )
    })
    reject_deploy_operation(() => {
      ignore(
        add_repository_deploy_key(pool, alice, repo, "Recreated", deleted_key),
      )
    })
    ignore(
      authorize_git_operation(
        pool,
        DeployKey(other_id),
        other,
        @repository.Read,
      ),
    )
  })
}

///|
async test "only managers can administer bindings and deploy credentials do not inherit creator identity" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let admin = @identity.active_user_by_name(pool, "admin")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let other : @domain.RepoId = { owner: "alice", name: "public", }
    let key = deploy_test_key(b'\x05')
    reject_deploy_operation(() => {
      ignore(add_repository_deploy_key(pool, bob, repo, "Denied", key))
    })
    let id = add_repository_deploy_key(
      pool,
      admin,
      repo,
      "Admin created",
      key,
      write_access=true,
    )
    reject_deploy_operation(() => {
      ignore(repository_deploy_keys(pool, bob, repo))
    })
    reject_deploy_operation(() => {
      set_repository_deploy_key_access(pool, bob, repo, id, false)
    })
    reject_deploy_operation(() => {
      revoke_repository_deploy_key(pool, bob, repo, id)
    })
    reject_deploy_operation(() => {
      set_repository_deploy_key_access(pool, alice, other, id, false)
    })
    reject_deploy_operation(() => {
      revoke_repository_deploy_key(pool, alice, other, id)
    })
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member (team_id, user_id, role) VALUES (1, 2, 'member')",
        ),
      )
    })
    reject_deploy_operation(() => {
      ignore(repository_deploy_keys(pool, bob, repo))
    })
    reject_deploy_operation(() => {
      ignore(
        add_repository_deploy_key(
          pool,
          bob,
          repo,
          "Member",
          deploy_test_key(b'\x06'),
        ),
      )
    })
    reject_deploy_operation(() => {
      ignore(
        authorize_git_operation(pool, DeployKey(id), other, @repository.Write),
      )
    })
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE \"user\" SET status = 'disabled' WHERE id = ?", params=[
          admin.id,
        ]),
      )
      ignore(
        client.execute("UPDATE repository SET ready = 0 WHERE name = 'demo'"),
      )
    })
    assert_true(authorized_ssh_key(pool, key) is None)
    reject_deploy_operation(() => {
      ignore(
        authorize_git_operation(pool, DeployKey(id), repo, @repository.Read),
      )
    })
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE repository SET ready = 1 WHERE name = 'demo'"),
      )
    })
    // A deploy key belongs to the repository, not to the creator's user account.
    ignore(
      authorize_git_operation(pool, DeployKey(id), repo, @repository.Write),
    )
    revoke_repository_deploy_key(pool, alice, repo, id)
  })
}

///|
test "SSH credential identifiers reject invalid or ambiguous kinds" {
  for
    value in [
      "", "0", "-1", "deploy:0", "deploy:-1", "deploy:", "user:1", "deploy:1;id",
      "deploy:9223372036854775808",
    ] {
    reject_deploy_operation(() => ignore(SshCredential::parse(value)))
  }
}
