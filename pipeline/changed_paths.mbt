///|
// Read names, not a textual patch: -z preserves tabs/newlines and --no-renames
// exposes both sides of moves. Keep stderr separate: even a successful Git
// warning must not become part of the first filename and hide a relevant edit.
async fn changed_paths(
  git_dir : String,
  base : String,
  head : String,
) -> Array[String]? {
  guard @gitops.valid_commit_sha(base) &&
    @gitops.valid_commit_sha(head) &&
    !base.iter().all(ch => ch == '0') else {
    return None
  }
  try {
    let output = @async.with_timeout(10000, () => {
      @async.with_task_group(group => {
        let (reader, writer) = @process.read_from_process()
        defer reader.close()
        let process = @process.spawn(
          group,
          "git",
          [
            "--git-dir", git_dir, "-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false",
            "diff", "--name-only", "--no-renames", "--no-ext-diff", "--no-textconv",
            "-z", base, head, "--",
          ],
          inherit_env=false,
          extra_env={
            "PATH": "/usr/bin:/bin",
            "HOME": "/nonexistent",
            "LANG": "C.UTF-8",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_TERMINAL_PROMPT": "0",
          },
          stdin=@process.redirect_from_file("/dev/null"),
          stdout=writer,
          stderr=@process.redirect_to_file("/dev/null"),
        )
        let bytes : Array[Byte] = []
        while reader.read_some(max_len=8192) is Some(chunk) {
          guard bytes.length() + chunk.length() <= 2097152 else {
            raise @domain.BadRequest(message="path diff exceeds limits")
          }
          bytes.push_iter(chunk.iter())
        }
        guard process.wait() == 0 else {
          raise @domain.BadRequest(message="path diff unavailable")
        }
        @utf8.decode(Bytes::from_array(bytes))
      })
    })
    let paths = output
      .split("\u{0000}")
      .filter(path => !path.is_empty())
      .map(path => path.to_owned())
      .collect()
    guard paths.length() <= 10000 && paths.all(path => path.length() <= 1024) else {
      return None
    }
    Some(paths)
  } catch {
    _ => None
  }
}
