///|
async test "repository variables expose nonsecret values to readers and restrict writes to managers" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let public_repo : @domain.RepoId = { owner: "alice", name: "public", }
    save_variable(pool, alice, repo, "openseek_s3_region", "us-east-1", 0L)
    save_variable(
      pool, alice, public_repo, "NOTICE", "visible-configuration", 0L,
    )
    let variable = list_variables(pool, alice, repo)[0]
    assert_eq(variable.name, "OPENSEEK_S3_REGION")
    assert_eq(variable.value, "us-east-1")
    assert_true(variable.version > 0L)
    assert_true(!variable.created_at.is_empty())
    assert_true(!variable.updated_at.is_empty())
    assert_eq(
      list_variables(pool, bob, public_repo)[0].value,
      "visible-configuration",
    )
    try ignore(list_variables(pool, bob, repo)) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("outsider read private repository variables")
    }
    try save_variable(pool, bob, public_repo, "NOTICE", "outsider", 0L) catch {
      @domain.NotFound(_) | @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("repository reader changed variables")
    }
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id,user_id,role) VALUES(1,2,'member')",
        ),
      )
    })
    assert_eq(list_variables(pool, bob, repo)[0].value, "us-east-1")
    try
      save_variable(
        pool,
        bob,
        repo,
        variable.name,
        "member-change",
        variable.version,
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("ordinary team member changed repository variables")
    }
    try
      delete_variable(pool, bob, repo, variable.name, variable.version)
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("ordinary team member deleted repository variables")
    }
    let admin = @identity.active_user_by_name(pool, "admin")
    save_variable(
      pool,
      admin,
      repo,
      variable.name,
      "admin-change",
      variable.version,
    )
    assert_eq(list_variables(pool, alice, repo)[0].value, "admin-change")
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE \"user\" SET status='disabled' WHERE id=?", params=[
          bob.id,
        ]),
      )
    })
    try ignore(list_variables(pool, bob, public_repo)) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("disabled account read repository variables")
    }
  })
}

///|
async test "repository variables normalize names preserve exact strings and reject stale revisions" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let value = "  first\n${{ vars.OTHER }}\nlast  "
    save_variable(pool, alice, repo, "message", value, 0L)
    let first = list_variables(pool, alice, repo)[0]
    assert_eq(first.value, value)
    try save_variable(pool, alice, repo, "MESSAGE", "stale", 0L) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("case variant or stale create overwrote an existing variable")
    }
    save_variable(pool, alice, repo, "mEsSaGe", "", first.version)
    let updated = list_variables(pool, alice, repo)[0]
    assert_eq(updated.name, "MESSAGE")
    assert_eq(updated.value, "")
    assert_true(updated.version > first.version)
    try delete_variable(pool, alice, repo, "MESSAGE", first.version) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale delete removed current variable")
    }
    delete_variable(pool, alice, repo, "message", updated.version)
    try
      save_variable(pool, alice, repo, "message", "stale", updated.version)
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale update recreated a deleted variable")
    }
    save_variable(pool, alice, repo, "message", "recreated", 0L)
    let recreated = list_variables(pool, alice, repo)[0]
    assert_true(recreated.version > updated.version)
    try delete_variable(pool, alice, repo, "MESSAGE", updated.version) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale revision matched a recreated variable")
    }
    pool.with_client(client => {
      let audit = client.query_all(
        "SELECT kind,detail FROM repository_audit WHERE kind LIKE 'variable_%'",
      )
      assert_eq(audit.length(), 4)
      for row in audit {
        assert_eq((row.get_name("detail") : String), "MESSAGE")
      }
      let other = client.query_one(
        "SELECT id FROM repository WHERE name='public'",
      )
      client.with_transaction(tx => {
        assert_true(snapshot_variables(tx, other.get_name("id")).is_empty())
        assert_eq(snapshot_variables(tx, 1L)["MESSAGE"], "recreated")
      })
    })
    assert_eq(list_variables(pool, alice, repo).length(), 1)
  })
}

///|
async test "repository variable names and per-value UTF8 limits are enforced" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    for
      name in [
        "",
        "1VALUE",
        "BAD-NAME",
        "bad.name",
        "值",
        "x".repeat(101),
        "GITHUB_VALUE",
        "github_value",
        "RUNNER_VALUE",
        "MOONHUB_VALUE",
        "__proto__",
        "constructor",
        "prototype",
      ] {
      try save_variable(pool, alice, repo, name, "value", 0L) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid variable name accepted: " + name)
      }
    }
    try save_variable(pool, alice, repo, "NEGATIVE", "value", -1L) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("negative version accepted")
    }
    for value in ["a\u{0000}b", "x".repeat(49153), "文".repeat(16385)] {
      try save_variable(pool, alice, repo, "VALUE", value, 0L) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("oversized or NUL variable accepted")
      }
    }
    save_variable(pool, alice, repo, "VALUE", "文".repeat(16384), 0L)
    assert_eq(
      @utf8.encode(list_variables(pool, alice, repo)[0].value).length(),
      49152,
    )
  })
}

///|
async test "repository variable count and escaped JSON snapshot limits are atomic" {
  @test_support.with_ssh_test_db(pool => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    for i in 0..<500 {
      save_variable(pool, alice, repo, "VALUE_" + i.to_string(), "", 0L)
    }
    assert_eq(list_variables(pool, alice, repo).length(), 500)
    try save_variable(pool, alice, repo, "EXTRA", "", 0L) catch {
      @domain.BadRequest(message~) => assert_true(message.contains("500"))
      err => raise err
    } noraise {
      _ => fail("501st repository variable accepted")
    }
    let current = list_variables(pool, alice, repo)[0]
    save_variable(pool, alice, repo, current.name, "updated", current.version)
    assert_eq(list_variables(pool, alice, repo).length(), 500)
    pool.with_client(client => {
      ignore(
        client.execute("DELETE FROM repository_variable WHERE repository_id=1"),
      )
    })
    // JSON escapes this control character into six bytes, so payload size cannot use raw size.
    let first = "\u{0001}".repeat(40000)
    save_variable(pool, alice, repo, "FIRST", first, 0L)
    try
      save_variable(pool, alice, repo, "SECOND", "\u{0001}".repeat(4000), 0L)
    catch {
      @domain.BadRequest(message~) => assert_true(message.contains("256 KiB"))
      err => raise err
    } noraise {
      _ => fail("oversized JSON snapshot accepted")
    }
    let values = list_variables(pool, alice, repo)
    assert_eq(values.length(), 1)
    assert_eq(values[0].value, first)
    try
      save_variable(
        pool,
        alice,
        repo,
        "FIRST",
        "\u{0001}".repeat(44000),
        values[0].version,
      )
    catch {
      @domain.BadRequest(message~) => assert_true(message.contains("256 KiB"))
      err => raise err
    } noraise {
      _ => fail("oversized JSON snapshot update accepted")
    }
    assert_eq(list_variables(pool, alice, repo)[0].version, values[0].version)
    assert_eq(list_variables(pool, alice, repo)[0].value, first)
  })
}
