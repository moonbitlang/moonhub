///|
test "ports accept only nonzero TCP port numbers" {
  assert_eq(@config.parse_port("1"), Some(1))
  assert_eq(@config.parse_port("8080"), Some(8080))
  assert_eq(@config.parse_port("65535"), Some(65535))
  for value in ["", "0", "65536", "-1", " 22", "22 ", "ssh", "22.0"] {
    assert_true(@config.parse_port(value) is None, msg=value)
  }
}
