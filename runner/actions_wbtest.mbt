///|
async test "native action execution preserves environment secrets output state and posts across processes" {
  @test_support.with_runner_workspace((root, launcher, workspace) => {
    let source_dir = root + "/source"
    let action = source_dir + "/.github/actions/fixture"
    @fs.mkdir(action, recursive=true)
    @fs.write_file(
      action + "/action.yml",
      (
        #|inputs:
        #|  access-token:
        #|    default: ''
        #|runs:
        #|  using: node24
        #|  main: main.cjs
        #|  post: post.cjs
      ),
    )
    @fs.write_file(
      action + "/main.cjs",
      (
        #|const fs = require('fs');
        #|if (process.env['INPUT_ACCESS-TOKEN'] !== 'issued-value') process.exit(2);
        #|if (process.env['INPUT_REF-LABEL'] !== '${{ secrets.NOT_RECURSIVE }}') process.exit(3);
        #|fs.appendFileSync(process.env.GITHUB_ENV, 'EXPORTED=action-value\n');
        #|fs.appendFileSync(process.env.GITHUB_OUTPUT, 'result=ready\n');
        #|fs.appendFileSync(process.env.GITHUB_STATE, 'saved=cleanup-value\n');
        #|fs.writeFileSync(process.env.GITHUB_WORKSPACE + '/executed', 'yes');
      ),
    )
    @fs.write_file(
      action + "/post.cjs",
      (
        #|require('fs').writeFileSync(process.env.GITHUB_WORKSPACE + '/post', process.env.STATE_saved);
      ),
    )
    let archive = root + "/source.tar"
    assert_eq(
      @process.run("tar", ["-cf", archive, "-C", source_dir, ".github"]),
      0,
    )
    let bytes = @fs.read_file(archive).binary()
    let fixture = {
      ..test_step("action", "", shell=""),
      uses: "./.github/actions/fixture",
      remote: true,
      inputs: {
        "access-token": "",
        "ref-label": "${{ secrets.NOT_RECURSIVE }}",
      },
      env: { "EXPORTED": "workflow" },
      secret_env: { "INPUT_ACCESS-TOKEN": "ACCESS_TOKEN" },
    }
    let assignment = {
      ..test_assignment([
        fixture,
        {
          ..test_step(
            "after", "test \"$EXPORTED\" = action-value; test -f executed; test ! -f post; test \"$RESULT\" = ready; test -z \"${INPUT_ACCESS_TOKEN:-}\"",
          ),
          templates: { "env:RESULT": "${{ steps.action.outputs.result }}" },
          env: { "EXPORTED": "workflow" },
        },
      ]),
      version: @protocol.remote_assignment_version,
    }
    let server = fake_server()
    let (code, node) = @process.collect_output_merged("node", [
      "-p", "process.execPath",
    ])
    assert_eq(code, 0)
    let runtime = @fs.realpath("runner/actions/runtime.mjs")
    let report = execute_assignment(
      assignment,
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
      source=() => bytes,
      action_node=node.text().trim().to_owned(),
      action_runtime=runtime,
      secrets=request => {
        assert_eq(request.step_id, "action")
        { version: 1, env: { "INPUT_ACCESS-TOKEN": "issued-value" }, }
      },
    )
    assert_eq(report.conclusion, "success")
    assert_true(report.reported)
    assert_eq(report.steps.map(step => step.state), ["success", "success"])
    assert_eq(
      @fs.read_file(workspace + "/repository/post").text(),
      "cleanup-value",
    )
    assert_true(@fs.exists(workspace + "/.home/.moon"))
    assert_true(
      !@fs.read_file(workspace + "/.tmp/state.json")
      .text()
      .contains("issued-value"),
    )
  })
}

///|
async test "native runtime continues status cleanup after failure and reports skipped steps" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let assignment = {
      ..test_assignment([
        test_step("fail", "exit 7"),
        test_step("skipped", "touch must-not-run"),
        {
          ..test_step("failure", "touch failure-cleanup"),
          templates: { "if": "failure()" },
        },
        {
          ..test_step("always", "touch always-cleanup"),
          templates: { "if": "always()" },
        },
      ]),
      version: @protocol.remote_assignment_version,
    }
    let server = fake_server()
    let (code, node) = @process.collect_output_merged("node", [
      "-p", "process.execPath",
    ])
    assert_eq(code, 0)
    let report = execute_assignment(
      assignment,
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
      action_node=node.text().trim().to_owned(),
      action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
    )
    assert_eq(report.conclusion, "failure")
    assert_true(report.reported)
    assert_eq(report.steps.map(step => step.state), [
      "failure", "skipped", "success", "success",
    ])
    assert_true(!@fs.exists(workspace + "/repository/must-not-run"))
    assert_true(@fs.exists(workspace + "/repository/failure-cleanup"))
    assert_true(@fs.exists(workspace + "/repository/always-cleanup"))
  })
}

///|
async test "native cancellation stops action runtime child process groups" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let assignment = {
      ..test_assignment([
        {
          ..test_step("sleep", "sleep 20; touch survivor"),
          templates: { "if": "always()" },
        },
      ]),
      version: @protocol.remote_assignment_version,
    }
    let server = fake_server(cancel_after=2)
    let (code, node) = @process.collect_output_merged("node", [
      "-p", "process.execPath",
    ])
    assert_eq(code, 0)
    let report = execute_assignment(
      assignment,
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
      action_node=node.text().trim().to_owned(),
      action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
    )
    assert_eq(report.conclusion, "cancelled")
    assert_true(report.reported)
    assert_true(!@fs.exists(workspace + "/repository/survivor"))
  })
}

///|
async test "native action jobs keep MoonBit setup outside the checkout directory" {
  @test_support.with_runner_workspace((root, launcher, workspace) => {
    let source_dir = root + "/source"
    @fs.mkdir(source_dir)
    @fs.write_file(source_dir + "/README.md", "pinned")
    let archive = root + "/source.tar"
    assert_eq(
      @process.run("tar", ["-cf", archive, "-C", source_dir, "README.md"]),
      0,
    )
    let bytes = @fs.read_file(archive).binary()
    let assignment = {
      ..test_assignment([
        setup_step("setup", "nightly"),
        { ..test_step("checkout", "", shell=""), uses: "moonhub/checkout@v1", },
        {
          ..test_step(
            "after",
            (
              #|test -f README.md
              #|test "$MOON_HOME" = "$HOME/moonbit-0"
              #|test "$(moon version --all)" = nightly
            ),
          ),
          templates: { "if": "success()" },
        },
      ]),
      version: @protocol.remote_assignment_version,
    }
    let server = fake_server()
    let (code, node) = @process.collect_output_merged("node", [
      "-p", "process.execPath",
    ])
    assert_eq(code, 0)
    let report = execute_assignment(
      assignment,
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
      source=() => bytes,
      moonbit_installer=() => @utf8.encode(fixture_installer),
      action_node=node.text().trim().to_owned(),
      action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
    )
    assert_eq(report.conclusion, "success")
    assert_true(report.reported)
    assert_true(report.steps.all(step => step.state == "success"))
    assert_true(@fs.exists(workspace + "/.home/moonbit-0/bin/moon"))
  })
}

///|
async test "contents none jobs do not fetch source or expose a source token" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let base = test_assignment([
      test_step("check", "test -z \"$TOKEN\"; echo no-source"),
    ])
    let assignment = {
      ..base,
      version: @protocol.remote_assignment_version,
      job: {
        ..base.job,
        contents_read: false,
        steps: [
          {
            ..base.job.steps[0],
            templates: { "env:TOKEN": "${{ github.token }}" },
          },
        ],
      },
    }
    let server = fake_server()
    let (code, node) = @process.collect_output_merged("node", [
      "-p", "process.execPath",
    ])
    assert_eq(code, 0)
    let report = execute_assignment(
      assignment,
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
      source=() => fail("unexpected source"),
      bundle=() => fail("unexpected bundle"),
      action_node=node.text().trim().to_owned(),
      action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
    )
    assert_eq(report.conclusion, "success")
    assert_true(report.reported)
  })
}

///|
test "runner environment checks prevent mislabeled distro versions and architectures" {
  let labels = ["self-hosted", "linux", "x64", "ubuntu-24.04"]
  validate_runner_environment(
    labels, "ID=ubuntu\nVERSION_ID=\"24.04\"\n", "x86_64",
  )
  for
    (release, arch) in [
      ("ID=debian\nVERSION_ID=12", "x86_64"),
      ("ID=ubuntu\nVERSION_ID=22.04", "x86_64"),
      ("ID=ubuntu\nVERSION_ID=24.04", "aarch64"),
    ] {
    try validate_runner_environment(labels, release, arch) catch {
      InvalidConfiguration(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted incompatible runner environment")
    }
  }
}
