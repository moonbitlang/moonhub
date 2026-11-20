///|
test "provider protocol helpers reject unsupported versions and invalid tokens" {
  try check_version(2) catch {
    @domain.BadRequest(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted version")
  }
  for token in ["", "b".repeat(63), "B".repeat(64), "x".repeat(64)] {
    try check_token(token) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted token")
    }
  }
}
