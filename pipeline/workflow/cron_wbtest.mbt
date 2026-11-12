///|
test "UTC cron validates ranges lists steps and day semantics" {
  assert_true(cron_matches("0 6 * * *", 0, 6, 12, 11, 4))
  assert_false(cron_matches("0 6 * * *", 1, 6, 12, 11, 4))
  assert_true(cron_matches("*/15 6-9 * 1,11 1-5", 30, 8, 12, 11, 4))
  assert_true(cron_matches("0 0 1 * 0", 0, 0, 15, 11, 0))
  for
    invalid in [
      "@daily", "0 6 * *", "60 * * * *", "*/0 * * * *", "0 24 * * *", "0 * 0 * *",
      "0 * * 13 *", "0 * * * 8",
    ] {
    try ignore(cron_matches(invalid, 0, 0, 1, 1, 0)) catch {
      InvalidWorkflow(_) => ()
    } noraise {
      _ => fail("invalid cron accepted")
    }
  }
}
