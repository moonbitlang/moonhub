///|
test "configuration schema rejects unknown values, duplicates and unsafe integer input" {
  let count : @protocol.ConfigField = {
    name: "count",
    title: "Count",
    kind: "integer",
    required: true,
    minimum: 1,
    maximum: 20,
    choices: [],
    help: "Workers",
  }
  let mode : @protocol.ConfigField = {
    name: "mode",
    title: "Mode",
    kind: "choice",
    required: true,
    minimum: 0,
    maximum: 0,
    choices: ["spot", "on-demand"],
    help: "Policy",
  }
  assert_eq(
    @protocol.validate_config([count, mode], { "count": "2", "mode": "spot" }),
    None,
  )
  for value in ["0", "21", "01", "-1", "1.5", "2\n", "9223372036854775808"] {
    assert_true(
      @protocol.validate_config([count], { "count": value }) is Some(_),
    )
  }
  assert_true(
    @protocol.validate_config([count, count], { "count": "2" }) is Some(_),
  )
  assert_true(
    @protocol.validate_config([mode], { "mode": "unknown" }) is Some(_),
  )
  assert_true(
    @protocol.validate_config([count], { "count": "2", "aws_secret": "hidden" })
    is Some(_),
  )
  assert_true(
    @protocol.validate_config([{ ..count, name: "bad-name", }], {}) is Some(_),
  )
}
