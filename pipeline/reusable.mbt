///|
// Every source is read from the already pinned caller commit, never a branch.
async fn read_workflow_definition(
  git_dir : String,
  sha : String,
  source : String,
  jobs~ : Array[String] = [],
) -> @workflow.Workflow {
  let sources : Map[String, String] = Map([])
  let pending = @workflow.reusable_paths(source, jobs~)
  let mut index = 0
  let mut bytes = @utf8.encode(source).length()
  while index < pending.length() {
    let path = pending[index]
    index += 1
    if sources.contains(path) {
      continue
    }
    guard sources.length() < 64 else {
      raise @domain.BadRequest(
        message="reusable workflow closure exceeds 64 files",
      )
    }
    let callee = read_workflow_source(git_dir, sha, path)
    bytes += @utf8.encode(callee).length()
    guard bytes <= 1048576 else {
      raise @domain.BadRequest(message="reusable workflow sources exceed 1 MiB")
    }
    sources[path] = callee
    for path in @workflow.reusable_paths(callee) {
      if !pending.contains(path) {
        pending.push(path)
      }
    }
  }
  @workflow.parse(source, jobs~, reusable=sources)
}
