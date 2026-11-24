///|
test "mixed OS plans retain conditional shells and cmd defaults" {
  let source =
    #|on: workflow_dispatch
    #|jobs:
    #|  build:
    #|    runs-on: ${{ matrix.os }}
    #|    strategy:
    #|      matrix:
    #|        os: [ubuntu-24.04, macos-14, windows-2022, ubuntu-22.04-arm]
    #|    steps:
    #|      - if: runner.os == 'Windows'
    #|        shell: pwsh
    #|        run: Write-Output windows
    #|      - if: runner.os != 'Windows'
    #|        shell: bash
    #|        run: echo unix
  let jobs = parse(source).jobs
  assert_eq(jobs.length(), 4)
  assert_eq(jobs[3].runs_on, ["self-hosted", "linux", "arm64", "ubuntu-22.04"])
  for job in jobs {
    assert_eq(job.steps[0].shell, Some("pwsh"))
  }
  expect_invalid(
    source.replace_all(old="shell: pwsh", new="shell: powershell-unknown"),
    "supports only",
  )
  let cmd = parse(
    "defaults: {run: {shell: cmd}}\n" +
    basic_workflow.replace_all(old="[self-hosted, linux]", new="windows-2022"),
  )
  assert_eq(cmd.jobs[0].steps[0].shell, Some("cmd"))
  assert_true(cmd.jobs[0].compatibility_runtime)
}

///|
test "runner groups combine with literal and matrix labels" {
  let source =
    #|on: workflow_dispatch
    #|jobs:
    #|  build:
    #|    runs-on:
    #|      group: ${{ matrix.pool }}
    #|      labels: ${{ matrix.node.labels }}
    #|    strategy:
    #|      matrix:
    #|        pool: [Trusted]
    #|        node: [{labels: [self-hosted, linux, arm64]}]
    #|    steps: [{run: echo group}]
  let job = parse(source).jobs[0]
  assert_eq(job.runner_group, "trusted")
  assert_eq(job.runs_on, ["self-hosted", "linux", "arm64"])
  let only = parse(
    basic_workflow.replace_all(
      old="[self-hosted, linux]",
      new="{group: trusted}",
    ),
  )
  assert_eq(only.jobs[0].runs_on, ["self-hosted"])
  assert_eq(
    parse(
      basic_workflow.replace_all(
        old="[self-hosted, linux]",
        new="{group: trusted, labels: gpu}",
      ),
    ).jobs[0].runs_on,
    ["gpu", "self-hosted"],
  )
  for
    selector in [
      "{group: ''}", "{group: invalid/name}", "{labels: linux}", "{group: trusted, unknown: true}",
    ] {
    expect_invalid(
      basic_workflow.replace_all(old="[self-hosted, linux]", new=selector),
      "",
    )
  }
}
