///|
// Executable fixtures belong on the build filesystem: job /tmp is noexec,
// and async/fs tmpdir currently ignores TMPDIR on Linux.
async fn executable_tmpdir(prefix : String) -> String {
  @fs.mkdir("_build/test-fixtures", permission=0o700) catch {
    err if @async.is_cancellation_error(err) => raise err
    err => {
      guard @fs.kind("_build/test-fixtures", follow_symlink=false) is Directory else {
        raise err
      }
    }
  }
  let base = @fs.realpath("_build/test-fixtures")
  let (code, output) = @process.collect_output_merged("mktemp", [
    "-d",
    "\{base}/\{prefix}XXXXXX",
  ])
  assert_eq(code, 0, msg=output.text())
  output.text().trim().to_owned()
}
