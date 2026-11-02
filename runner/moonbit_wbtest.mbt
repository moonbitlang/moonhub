///|
fn setup_step(id : String, version : String) -> @protocol.StepPlan {
  {
    ..test_step(id, "", shell=""),
    uses: "moonhub/setup-moonbit@v1",
    moonbit_version: version,
  }
}

///|
let fixture_installer : String =
  #|set -eu
  #|test "$#" -eq 1
  #|case "$MOON_HOME" in "$HOME"/moonbit-*) ;; *) exit 41 ;; esac
  #|test ! -L "$MOON_HOME"
  #|mkdir -p "$MOON_HOME/bin" "$MOON_HOME/lib/core"
  #|printf '%s\n' "$1" > "$MOON_HOME/requested-version"
  #|cat > "$MOON_HOME/bin/moon" <<'COMMAND'
  #|#!/bin/sh
  #|cat "$MOON_HOME/requested-version"
  #|COMMAND
  #|cp "$MOON_HOME/bin/moon" "$MOON_HOME/bin/moonc"
  #|cp "$MOON_HOME/bin/moon" "$MOON_HOME/bin/moonrun"
  #|chmod +x "$MOON_HOME/bin/moon" "$MOON_HOME/bin/moonc" "$MOON_HOME/bin/moonrun"

///|
async test "setup selects job-local toolchain for subsequent steps and supports switching versions" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let server = fake_server()
    let assignment = {
      ..test_assignment([
        test_step(
          "before", "test \"$MOON_HOME\" = \"$HOME/.moon\"; test ! -e \"$HOME/moonbit-1\"",
        ),
        setup_step("setup", "0.10.17+093cb8f9c"),
        test_step(
          "first",
          (
            #|test "$MOON_HOME" = "$HOME/moonbit-1"
            #|test "$(command -v moon)" = "$MOON_HOME/bin/moon"
            #|test "$(moon version --all)" = 0.10.17+093cb8f9c
            #|test "$(moonc -v)" = 0.10.17+093cb8f9c
            #|test "$(moonrun --version)" = 0.10.17+093cb8f9c
            #|test -z "${MOONHUB_MOONBIT_INSTALLER+x}"
            #|test -z "${MOONHUB_MOONBIT_VERSION+x}"
          ),
          env={
            "PATH": "/usr/bin:/bin",
            "MOON_HOME": "/should-not-select-this",
          },
        ),
        setup_step("switch", "nightly"),
        test_step(
          "after",
          (
            #|test "$MOON_HOME" = "$HOME/moonbit-3"
            #|test "$(moon version --all)" = nightly
            #|test "$(cat "$HOME/moonbit-1/requested-version")" = 0.10.17+093cb8f9c
          ),
        ),
      ]),
      version: @protocol.toolchain_assignment_version,
    }
    let mut downloads = 0
    let report = execute_assignment(
      assignment,
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
      moonbit_installer=() => {
        downloads += 1
        @utf8.encode(fixture_installer)
      },
    )
    assert_eq(report.conclusion, "success")
    assert_true(report.reported)
    assert_eq(downloads, 2)
    assert_true(report.steps.all(step => step.state == "success"))
    assert_true(
      server.logs.any(log => {
        log.step_id == "setup" && log.text.contains("0.10.17+093cb8f9c")
      }),
    )
    assert_true(
      server.logs.any(log => {
        log.step_id == "switch" && log.text.contains("nightly")
      }),
    )
    assert_true(
      @fs.kind(workspace + "/.home/moonbit-1/bin", follow_symlink=false)
      is Directory,
    )
  })
}

///|
async test "setup works on either side of checkout and preserves automatic source preparation" {
  @test_support.with_runner_workspace((root, launcher, _) => {
    let source_dir = root + "/source"
    @fs.mkdir(source_dir)
    @fs.write_file(source_dir + "/README.md", "pinned")
    let archive = root + "/source.tar"
    assert_eq(
      @process.run("tar", ["-cf", archive, "-C", source_dir, "README.md"]),
      0,
    )
    let bytes = @fs.read_file(archive).binary()
    let checkout = {
      ..test_step("checkout", "", shell=""),
      uses: "moonhub/checkout@v1",
    }
    for order in ["before", "after", "implicit"] {
      let workspace = root + "/" + order
      @fs.mkdir(workspace)
      let server = fake_server()
      let setup = setup_step("setup", "latest")
      let steps = match order {
        "before" => [setup, checkout]
        "after" => [checkout, setup]
        _ => [setup]
      }
      steps.push(
        test_step(
          "check", "test -f README.md; test \"$(moon version --all)\" = latest",
        ),
      )
      let mut fetched = 0
      let report = execute_assignment(
        {
          ..test_assignment(steps),
          version: @protocol.toolchain_assignment_version,
        },
        test_options(launcher, workspace),
        (operation, body, until) => server.post(operation, body, until),
        source=() => {
          fetched += 1
          bytes
        },
        moonbit_installer=() => @utf8.encode(fixture_installer),
      )
      assert_eq(report.conclusion, "success", msg=order)
      assert_eq(fetched, 1)
    }
  })
}

///|
async test "failed download install or incomplete toolchain stops later steps and belongs to setup" {
  @test_support.with_runner_workspace((root, launcher, _) => {
    for mode in ["download", "install", "incomplete"] {
      let workspace = root + "/" + mode
      @fs.mkdir(workspace)
      let server = fake_server()
      let report = execute_assignment(
        {
          ..test_assignment([
            setup_step("setup", "latest"),
            test_step("after", "touch executed"),
          ]),
          version: @protocol.toolchain_assignment_version,
        },
        test_options(launcher, workspace),
        (operation, body, until) => server.post(operation, body, until),
        moonbit_installer=() => {
          if mode == "download" {
            raise InvalidConfiguration("fixture download failure")
          }
          @utf8.encode(if mode == "install" { "exit 17" } else { "exit 0" })
        },
      )
      assert_eq(report.conclusion, "failure", msg=mode)
      assert_eq(report.steps[0].state, "failure")
      assert_eq(report.steps[1].state, "skipped")
      assert_true(report.reported)
      assert_true(!@fs.exists(workspace + "/executed"))
      assert_true(server.logs.any(log => log.step_id == "setup"))
      if mode == "install" {
        assert_eq(report.steps[0].exit_code, 17)
      }
    }
  })
}

///|
async test "cancellation and fixed job deadlines interrupt setup downloads and installers" {
  @test_support.with_runner_workspace((root, launcher, _) => {
    for phase in ["download", "install"] {
      for reason in ["cancelled", "timed_out"] {
        let workspace = root + "/" + phase + "-" + reason
        @fs.mkdir(workspace)
        let server = if reason == "cancelled" {
          fake_server(cancel_after=3)
        } else {
          fake_server(job_ms=1250L)
        }
        let report = execute_assignment(
          {
            ..test_assignment([
              setup_step("setup", "latest"),
              test_step("after", "touch executed"),
            ]),
            version: @protocol.toolchain_assignment_version,
          },
          test_options(launcher, workspace),
          (operation, body, until) => server.post(operation, body, until),
          moonbit_installer=() => {
            if phase == "download" {
              @async.sleep(10000)
            }
            @utf8.encode("sleep 10")
          },
        )
        assert_eq(report.conclusion, reason, msg=phase)
        assert_eq(report.steps[0].state, reason)
        assert_eq(report.steps[1].state, "skipped")
        assert_true(!@fs.exists(workspace + "/executed"))
      }
    }
  })
}

///|
async test "setup rejects malformed versions legacy assignments and unrelated version inputs before start" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let base = setup_step("setup", "latest")
    let invalid = [
      { ..base, moonbit_version: "", },
      { ..base, moonbit_version: "../latest", },
      { ..base, moonbit_version: "stable", },
      { ..base, moonbit_version: "0.1;echo bad", },
      { ..base, run: "echo mixed", },
      { ..base, shell: "bash", },
      { ..base, env: { "PATH": "/tmp" }, },
      { ..base, working_directory: "src", },
      { ..base, uses: "moonbit-community/setup-moonbit@main", },
      { ..test_step("run", "touch executed"), moonbit_version: "latest", },
      { ..base, uses: "actions/checkout@v4", },
    ]
    for step in invalid {
      let server = fake_server()
      try
        ignore(
          execute_assignment(
            {
              ..test_assignment([step]),
              version: @protocol.toolchain_assignment_version,
            },
            test_options(launcher, workspace),
            (operation, body, until) => server.post(operation, body, until),
          ),
        )
      catch {
        InvalidConfiguration(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid setup")
      }
      assert_eq(server.execution_id, "")
    }
    for version in [@protocol.version, @protocol.action_assignment_version] {
      let server = fake_server()
      try
        ignore(
          execute_assignment(
            { ..test_assignment([base]), version, },
            test_options(launcher, workspace),
            (operation, body, until) => server.post(operation, body, until),
          ),
        )
      catch {
        InvalidConfiguration(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted setup with old assignment version")
      }
      assert_eq(server.execution_id, "")
    }
  })
}
