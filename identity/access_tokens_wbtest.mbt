///|
async test "API token scope expiry revocation disabled accounts and secret storage" {
  @test_support.with_ssh_test_db(pool => {
    let alice = active_user_by_name(pool, "alice")
    let bob = active_user_by_name(pool, "bob")
    let read = create_access_token(pool, alice, "Read CLI", "read", 30)
    assert_true(valid_access_token(read))
    assert_eq(authenticate_access_token(pool, read, "read").id, alice.id)
    try authenticate_access_token(pool, read, "write") catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("read token wrote")
    }
    let execute = create_access_token(pool, alice, "Execute", "execute", 1)
    assert_eq(authenticate_access_token(pool, execute, "write").id, alice.id)
    assert_eq(authenticate_access_token(pool, execute, "execute").id, alice.id)
    try authenticate_access_token(pool, execute, "merge") catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("execute token granted merge")
    }
    let id = access_tokens(pool, alice)[0].id
    try revoke_access_token(pool, bob, id) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("other user revoked token")
    }
    revoke_access_token(pool, alice, id)
    try authenticate_access_token(pool, execute, "read") catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("revoked token authenticated")
    }
    pool.with_client(client => {
      let stored : String = client
        .query_one("SELECT token_hash FROM access_token WHERE token_hash = ?", params=[
          hash_token(read),
        ])
        .get_name("token_hash")
      assert_true(stored != read)
      ignore(
        client.execute(
          "UPDATE access_token SET expires_at = datetime('now', '-1 day') WHERE token_hash = ?",
          params=[stored],
        ),
      )
    })
    try authenticate_access_token(pool, read, "read") catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("expired token authenticated")
    }
    let token = create_access_token(pool, alice, "Disabled", "merge", 1)
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE \"user\" SET status = 'disabled' WHERE id = ?", params=[
          alice.id,
        ]),
      )
    })
    try authenticate_access_token(pool, token, "merge") catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("disabled account token authenticated")
    }
  })
}
