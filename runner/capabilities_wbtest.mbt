///|
async test "capability probes use explicit signals and ignore command checks and unrelated exit codes" {
  @test_support.with_runner_workspace((root, launcher, workspace) => {
    let server = fake_server()
    let original = test_assignment([
      test_step("check", "docker build .\ntouch should-not-run"),
    ])
    let assignment = {
      ..original,
      version: @protocol.execution_assignment_version,
      execution: Some({
        environment: "ubuntu-x64",
        environment_version: "v1",
        profile: "restricted",
        probe_capabilities: true,
      }),
    }
    let (_, node) = @process.collect_output_merged("node", [
      "-p", "process.execPath",
    ])
    let observed = Ref("")
    let report = execute_assignment(
      assignment,
      test_options(launcher, workspace),
      (operation, body, until) => {
        if operation == "complete" {
          let completion : @protocol.CompleteRequest = @json.from_json(body)
          observed.val = completion.missing_capability
          let compatible = body
          if compatible is Object(fields) {
            ignore(fields.remove("outputs"))
          }
          server.post(operation, compatible, until)
        } else {
          server.post(operation, body, until)
        }
      },
      action_node=node.text().trim().to_owned(),
      action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
    )
    assert_eq(report.conclusion, "failure")
    assert_eq(observed.val, "docker")
    assert_false(@fs.exists(workspace + "/repository/should-not-run"))
    ignore(root)
  })
}

///|
async test "ordinary command failures and Docker remote endpoint failures do not request a profile change" {
  for
    command in [
      "exit 125", "echo 'Cannot connect to Docker daemon' >&2; exit 1", "docker --version",
      "DOCKER_HOST=tcp://example.invalid docker info",
    ] {
    @test_support.with_runner_workspace((_, launcher, workspace) => {
      let server = fake_server()
      let original = test_assignment([test_step("check", command)])
      let assignment = {
        ..original,
        version: @protocol.execution_assignment_version,
        execution: Some({
          environment: "ubuntu-x64",
          environment_version: "v1",
          profile: "restricted",
          probe_capabilities: true,
        }),
      }
      let (_, node) = @process.collect_output_merged("node", [
        "-p", "process.execPath",
      ])
      let observed = Ref("unset")
      let report = execute_assignment(
        assignment,
        test_options(launcher, workspace),
        (operation, body, until) => {
          if operation == "complete" {
            let completion : @protocol.CompleteRequest = @json.from_json(body)
            observed.val = completion.missing_capability
            if body is Object(fields) {
              ignore(fields.remove("outputs"))
            }
          }
          server.post(operation, body, until)
        },
        action_node=node.text().trim().to_owned(),
        action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
      )
      assert_eq(report.conclusion, "failure")
      assert_eq(observed.val, "")
    })
  }
}

///|
async test "capability signal reader rejects links oversized files and partial writes" {
  @test_support.with_runner_workspace((root, _, _) => {
    let file = root + "/request"
    let path = @utf8.encode(file + "\u{0000}")
    assert_eq(capability_read(path), 0)
    for
      (source, expected) in [
        ("docker\n", 1),
        ("container-root\n", 2),
        ("host-kernel\n", 3),
        ("docker", -1),
        ("", -1),
        ("x".repeat(65), -1),
      ] {
      @fs.write_file(file, source)
      assert_eq(capability_read(path), expected)
    }
    @fs.remove(file)
    @fs.symlink(target=root + "/missing", file)
    assert_eq(capability_read(path), -1)
  })
}
