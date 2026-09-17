///|
async test "strict Git text reads reject invalid UTF-8 and retain output bounds" {
  let root = @fs.tmpdir(prefix="moonhub-git-text-")
  defer @fs.rmdir(root, recursive=true)
  let git_dir = "\{root}/repo.git"
  let (code, output) = @process.collect_output_merged("git", [
    "init", "--bare", git_dir,
  ])
  assert_eq(code, 0, msg=output.text())
  let path = "\{root}/source"
  @fs.write_file(path, b"\xff\xfe")
  let blob = merge_git(git_dir, ["hash-object", "-w", path]).trim().to_owned()
  try
    ignore(
      merge_git_command(git_dir, ["cat-file", "blob", blob], strict_utf8=true),
    )
  catch {
    Failure(message~) => assert_true(message.contains("UTF-8"))
    err => raise err
  } noraise {
    _ => fail("invalid UTF-8 was silently replaced")
  }
  let (_, lossy) = merge_git_command(git_dir, ["cat-file", "blob", blob])
  assert_eq(lossy, "\u{fffd}\u{fffd}")
  @fs.write_file(path, "hello\n")
  let blob = merge_git(git_dir, ["hash-object", "-w", path]).trim().to_owned()
  let (code, text) = merge_git_command(
    git_dir,
    ["cat-file", "blob", blob],
    strict_utf8=true,
  )
  assert_eq(code, 0)
  assert_eq(text, "hello\n")
  try
    ignore(
      merge_git_command(
        git_dir,
        ["cat-file", "blob", blob],
        strict_utf8=true,
        limit=3,
      ),
    )
  catch {
    Failure(message~) => assert_true(message.contains("too large"))
    err => raise err
  } noraise {
    _ => fail("strict decoding bypassed the output limit")
  }
}
