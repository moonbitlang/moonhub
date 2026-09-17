///|
async test "the personal namespace migration backfills existing accounts and keeps foreign names" {
  @test_support.with_ssh_test_db(pool => {
    let migration = @fs.read_file("db/migrations/006_personal_namespaces.sql").text()
    pool.with_client(client => {
      let _ = client.execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash)
          #|VALUES (9, 'legacy', 'Legacy', 'test')
        ),
      )
      // A user whose name_key is already an organization keeps that namespace.
      let _ = client.execute(
        (
          #|INSERT INTO team (id, name_key, display_name, kind)
          #|VALUES (7, 'shared', 'Shared', 'org')
        ),
      )
      let _ = client.execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash)
          #|VALUES (10, 'shared', 'Shared Member', 'test')
        ),
      )
      // The migration must be replayable without duplicating namespaces.
      client.batch_execute(migration)
      client.batch_execute(migration)
    })
    let legacy = @identity.active_user_by_name(pool, "legacy")
    let personal = @identity.personal_namespace(pool, legacy).unwrap_or_else(() => {
      fail("existing account has no personal namespace")
    })
    assert_eq(personal.name_key, "legacy")
    assert_eq(personal.display_name, "Legacy")
    assert_eq(@identity.team_role(pool, legacy, personal.id), Some("owner"))
    assert_true(
      @identity.personal_namespace(
        pool,
        @identity.active_user_by_name(pool, "shared"),
      )
      is None,
    )
    let shared = @identity.get_team_by_name_key(pool, "shared").unwrap()
    assert_eq(shared.kind, "org")
    assert_eq(shared.display_name, "Shared")
    pool.with_client(client => {
      assert_eq(
        client
        .query_all("SELECT id FROM team WHERE name_key = 'legacy'")
        .length(),
        1,
      )
      assert_eq(
        client
        .query_all("SELECT id FROM team WHERE name_key = 'alice'")
        .length(),
        1,
      )
      assert_eq(
        client
        .query_all("SELECT team_id FROM team_member WHERE user_id = 9")
        .length(),
        1,
      )
      assert_true(
        client.query_opt("SELECT team_id FROM team_member WHERE user_id = 10")
        is None,
      )
    })
  })
}
