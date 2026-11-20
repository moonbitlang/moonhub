///|
test "streaming mask handles overlaps Unicode multiple values and multiline credentials" {
  assert_eq(mask_log("prefix abc", ["abc", "abcdef"]), ("prefix ", "abc"))
  assert_eq(
    mask_log("abcdef and abc!", ["abc", "abcdef"]),
    ("*** and ***!", ""),
  )
  assert_eq(
    mask_log("before 密钥 after", ["密钥"]),
    ("before *** after", ""),
  )
  let masks = secret_masks("one-secret\ntwo-secret\n")
  assert_eq(mask_log("one-secret and two-secret!", masks), ("*** and ***!", ""))
  assert_eq(
    mask_log(
      "nested-private-value!",
      secret_masks("{\"registry\": [{\"token\":\"nested-private-value\"}]}"),
    ),
    ("***!", ""),
  )
}
