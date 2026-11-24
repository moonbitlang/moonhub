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

///|
async test "IANA schedules advance missing minutes and fire only the first repeated minute" {
  let bytes = @fs.read_file(
    "pipeline/workflow/fixtures/timezones/America_New_York.tzif",
  ).binary()
  let zone = @time.Zone::from_tzif("America/New_York", bytes[:])
  let gap : Schedule = { cron: "30 2 * * *", timezone: "America/New_York", }
  let transition = @time.ZonedDateTime::of(
    2026,
    3,
    8,
    hour=7,
    zone=@time.utc_zone,
  ).to_unix_second()
  assert_false(gap.matches(transition - 60L, zone))
  assert_true(gap.matches(transition, zone))
  assert_false(gap.matches(transition + 1800L, zone))
  let overlap : Schedule = { cron: "30 1 * * *", timezone: "America/New_York", }
  let first = @time.ZonedDateTime::of(
    2026,
    11,
    1,
    hour=5,
    minute=30,
    zone=@time.utc_zone,
  ).to_unix_second()
  assert_true(overlap.matches(first, zone))
  assert_false(overlap.matches(first + 3600L, zone))
  let asia = @fs.read_file(
    "pipeline/workflow/fixtures/timezones/Asia_Shanghai.tzif",
  ).binary()
  let morning : Schedule = { cron: "0 8 * * *", timezone: "Asia/Shanghai", }
  assert_true(
    morning.matches(
      @time.ZonedDateTime::of(2026, 11, 24, zone=@time.utc_zone).to_unix_second(),
      @time.Zone::from_tzif("Asia/Shanghai", asia[:]),
    ),
  )
  let source = basic_workflow.replace_all(
    old="on: workflow_dispatch",
    new="on: {schedule: [{cron: '0 8 * * *', timezone: Asia/Shanghai}]}",
  )
  assert_eq(triggers(source).schedules[0].timezone, "Asia/Shanghai")
  for zone_name in ["../etc/passwd", "/UTC", "bad zone"] {
    expect_invalid(
      source.replace_all(old="Asia/Shanghai", new=zone_name),
      "timezone",
    )
  }
}
