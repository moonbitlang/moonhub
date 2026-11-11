///|
test "CI run accepts an inputs JSON file" {
  let parsed = command().parse(argv=[
    "ci", "run", "--branch", "master", "--workflow", ".github/workflows/release.yml",
    "--inputs-file", "/tmp/inputs.json", "--json", "--jobs", "build,test",
  ])
  assert_eq(option(parsed, "inputs-file"), Some("/tmp/inputs.json"))
  assert_eq(option(parsed, "jobs"), Some("build,test"))
  assert_eq(option(parsed, "workflow"), Some(".github/workflows/release.yml"))
}

///|
async test "dispatch inputs files preserve scalar types and reject malformed or oversized payloads" {
  let dir = @fs.tmpdir(prefix="moonhub-dispatch-cli-")
  defer @fs.rmdir(dir, recursive=true)
  let file = dir + "/inputs.json"
  @fs.write_file(
    file, "{\"version\":\"1.2.3\",\"release\":false,\"count\":2.5}",
  )
  let values = read_dispatch_inputs(file)
  assert_eq(values.get("version"), Some(Json("1.2.3")))
  assert_eq(values.get("release"), Some(Json(false)))
  assert_eq(values.get("count"), Some(Json(2.5)))
  for
    invalid in [
      "[]",
      "null",
      "{",
      "{\"x\":null}",
      "{\"x\":{}}",
      "{\"x\":[]}",
      " ".repeat(65536),
    ] {
    @fs.write_file(file, invalid)
    try read_dispatch_inputs(file) catch {
      Invalid(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid input file")
    }
  }
  let too_many : Map[String, Json] = Map([])
  for i in 0..<26 {
    too_many["input" + i.to_string()] = Json("")
  }
  @fs.write_file(file, ToJson::to_json(too_many).stringify())
  try read_dispatch_inputs(file) catch {
    Invalid(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted too many inputs")
  }
  @fs.write_file(file, Bytes::from_array([b'\xff']))
  try read_dispatch_inputs(file) catch {
    Invalid(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted invalid UTF-8")
  }
  try read_dispatch_inputs(dir) catch {
    Invalid(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted an input directory")
  }
}
