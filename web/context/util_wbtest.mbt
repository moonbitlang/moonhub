///|
test "form decoding keeps plus-for-space behavior with core percent decoding" {
  assert_eq(percent_decode("a+b%2Bc%2520"), "a b+c%20")
  assert_eq(percent_decode("%E6%96%87%E6%A1%A3%20%GG"), "文档 %GG")
}

///|
test "repository URL paths encode literal percent escapes and UTF-8 while retaining separators" {
  assert_eq(url_escape_path("feature/release-v3.0_~"), "feature/release-v3.0_~")
  assert_eq(
    url_escape_path("文档/%23 #?&+<>\""),
    "%E6%96%87%E6%A1%A3/%2523%20%23%3F%26%2B%3C%3E%22",
  )
}

///|
test "repository path decoding runs once and preserves literal plus signs" {
  assert_eq(decode_url_path("src/%2523+%23"), "src/%23+#")
  assert_eq(decode_url_path(url_escape_path("文档/#?%+<>")), "文档/#?%+<>")
  for invalid in ["%", "%2", "%GG", "%FF"] {
    try decode_url_path(invalid) catch {
      @domain.BadRequest(_) => ()
      _ => fail("expected a public bad request")
    } noraise {
      _ => fail("expected invalid path encoding to fail")
    }
  }
}
