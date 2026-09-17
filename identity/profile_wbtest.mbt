///|
async test "profile changes update only the account and its personal namespace" {
  @test_support.with_ssh_test_db(pool => {
    let alice = active_user_by_name(pool, "alice")
    let bob = active_user_by_name(pool, "bob")
    update_display_name(pool, alice, "Alice Updated")
    let profile = user_profile(pool, alice)
    assert_eq(profile.name_key, "alice")
    assert_eq(profile.display_name, "Alice Updated")
    assert_eq(
      personal_namespace(pool, alice).unwrap().display_name,
      "Alice Updated",
    )
    assert_eq(user_profile(pool, bob).display_name, "Bob")
    assert_eq(
      get_team_by_name_key(pool, "workshop").unwrap().display_name,
      "Workshop",
    )
  })
}
