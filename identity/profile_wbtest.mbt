///|
async test "profile changes update only the account and its personal namespace" {
  @test_support.with_ssh_test_db(pool => {
    let alice = active_user_by_name(pool, "alice")
    let bob = active_user_by_name(pool, "bob")
    update_profile(pool, alice, "Alice Updated", None)
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

///|
async test "display time zone preferences default to device and update only their owner" {
  @test_support.with_ssh_test_db(pool => {
    let alice = active_user_by_name(pool, "alice")
    let bob = active_user_by_name(pool, "bob")
    assert_eq(user_profile(pool, alice).time_zone, None)
    update_profile(pool, alice, "Alice", Some("Asia/Kathmandu"))
    assert_eq(user_profile(pool, alice).time_zone, Some("Asia/Kathmandu"))
    assert_eq(user_profile(pool, bob).time_zone, None)
    for
      zone in ["", "UTC+8", "Unknown/Zone", "../etc/passwd", "Asia/Shanghai\n"] {
      try update_profile(pool, alice, "Must not save", Some(zone)) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("invalid time zone accepted")
      }
      assert_eq(user_profile(pool, alice).display_name, "Alice")
      assert_eq(user_profile(pool, alice).time_zone, Some("Asia/Kathmandu"))
    }
    assert_true(valid_display_time_zone(Some("US/Pacific")))
    assert_true(valid_display_time_zone(Some("UTC")))
    assert_true(valid_display_time_zone(Some("America/Los_Angeles")))
    update_profile(pool, alice, "Alice", None)
    assert_eq(user_profile(pool, alice).time_zone, None)
  })
}
