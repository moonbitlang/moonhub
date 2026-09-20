///|
async test "executable fixtures get separate directories on the build filesystem" {
  let first = executable_tmpdir("moonhub-exec-")
  defer @fs.rmdir(first, recursive=true)
  let second = executable_tmpdir("moonhub-exec-")
  defer @fs.rmdir(second, recursive=true)
  assert_true(first != second)
  let base = @fs.realpath("_build/test-fixtures") + "/"
  assert_true(first.has_prefix(base))
  assert_true(second.has_prefix(base))
  let script = first + "/probe"
  @fs.write_file(script, "#!/bin/sh\nprintf fixture-ok\n", permission=0o700)
  let (code, output) = @process.collect_output_merged(script, [])
  assert_eq(code, 0)
  assert_eq(output.text(), "fixture-ok")
}
