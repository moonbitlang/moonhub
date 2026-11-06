///|
test "variable CLI uses explicit names and revision-bound file submission" {
  let parsed = command().parse(argv=[
    "variable", "set", "REGION", "--body-file", "/tmp/value.txt", "--version", "0",
  ])
  let (_, group) = parsed.subcommand.unwrap()
  let (_, options) = group.subcommand.unwrap()
  assert_eq(option(options, "name"), Some("REGION"))
  assert_eq(option(parsed, "body-file"), Some("/tmp/value.txt"))
  assert_eq(option(parsed, "version"), Some("0"))
  ignore(command().parse(argv=["variable", "list", "--json"]))
  ignore(
    command().parse(argv=["variable", "delete", "REGION", "--version", "1"]),
  )
}

///|
async test "variable CLI preserves empty UTF8 text and enforces file limits" {
  let dir = @fs.tmpdir(prefix="moonhub-variable-cli-")
  defer @fs.rmdir(dir, recursive=true)
  let file = dir + "/value.txt"
  for text in ["", "region\n", "字".repeat(16384)] {
    @fs.write_file(file, text)
    assert_eq(read_variable_value(file), text)
  }
  for text in ["x".repeat(49153), "a\u{0000}b"] {
    @fs.write_file(file, text)
    try ignore(read_variable_value(file)) catch {
      Invalid(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid variable file")
    }
  }
  @fs.write_file(file, Bytes::from_array([b'\xff']))
  try ignore(read_variable_value(file)) catch {
    Invalid(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted invalid UTF8")
  }
  try ignore(read_variable_value(dir)) catch {
    Invalid(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted variable directory")
  }
}
