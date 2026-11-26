///|
async test "site administrator grants require a live administrator account" {
  @test_support.with_ssh_test_db(pool => {
    let admin = active_user_by_name(pool, "admin")
    let bob = active_user_by_name(pool, "bob")
    for
      sql in [
        "UPDATE \"user\" SET is_site_admin = 0 WHERE id = 3", "UPDATE \"user\" SET is_site_admin = 1, status = 'disabled' WHERE id = 3",
      ] {
      pool.with_client(client => {
        let _ = client.execute(sql)
      })
      try grant_site_admin(pool, admin, bob.id) catch {
        @domain.Forbidden(_) => ()
        err => raise err
      } noraise {
        _ => fail("a former administrator could still grant access")
      }
      assert_true(!active_user_by_name(pool, "bob").is_site_admin)
    }
  })
}
