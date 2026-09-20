///|
pub async fn with_runner_workspace(
  f : async (String, String, String) -> Unit,
) -> Unit {
  let root = executable_tmpdir("moonhub-runner-test-")
  defer @fs.rmdir(root, recursive=true)
  let launcher = "\{root}/step-launcher"
  let (code, output) = @process.collect_output_merged("cc", [
    "-std=c11", "-Wall", "-Wextra", "-Werror", "runner/step-launcher.c", "-o", launcher,
  ])
  assert_eq(code, 0, msg=output.text())
  let workspace = "\{root}/workspace"
  @fs.mkdir(workspace)
  f(root, launcher, workspace)
}
