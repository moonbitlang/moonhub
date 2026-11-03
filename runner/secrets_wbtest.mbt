///|
async test "secret values are fetched only for their step and do not enter scripts or later env" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let secret_step = {
      ..test_step("secret", "printf '%s' \"$CREDENTIAL\" > observed"),
      secret_env: { "CREDENTIAL": "TOKEN" },
    }
    let assignment = {
      ..test_assignment([
        secret_step,
        test_step("after", "test \"${CREDENTIAL-unset}\" = unset"),
      ]),
      version: @protocol.secret_assignment_version,
    }
    let server = fake_server()
    let calls = Ref(0)
    let report = execute_assignment(
      assignment,
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
      secrets=request => {
        calls.val += 1
        assert_eq(request.step_id, "secret")
        assert_eq(request.execution_id, server.execution_id)
        { version: 1, env: { "CREDENTIAL": "值-$()-private" }, }
      },
    )
    assert_eq(report.conclusion, "success")
    assert_eq(calls.val, 1)
    assert_eq(@fs.read_file(workspace + "/observed").text(), "值-$()-private")
    assert_true(!assignment.to_json().stringify().contains("值-$()-private"))
  })
}

///|
async test "secret assignments fail closed for old versions forbidden targets and denied delivery" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let step = {
      ..test_step("secret", "touch executed"),
      secret_env: { "CREDENTIAL": "TOKEN" },
    }
    for version in [1, 2, 3] {
      let server = fake_server()
      try
        ignore(
          execute_assignment(
            { ..test_assignment([step]), version, },
            test_options(launcher, workspace),
            (operation, body, until) => server.post(operation, body, until),
          ),
        )
      catch {
        InvalidConfiguration(_) => ()
        err => raise err
      } noraise {
        _ => fail("old assignment exposed secret")
      }
      assert_true(server.events.is_empty())
    }
    for
      name in ["GITHUB_TOKEN", "BASH_ENV", "LD_PRELOAD", "1INVALID", "BAD-NAME"] {
      let server = fake_server()
      let secret_env : Map[String, String] = Map([(name, "TOKEN")])
      try
        ignore(
          execute_assignment(
            { ..test_assignment([{ ..step, secret_env, }]), version: 4, },
            test_options(launcher, workspace),
            (operation, body, until) => server.post(operation, body, until),
          ),
        )
      catch {
        InvalidConfiguration(_) => ()
        err => raise err
      } noraise {
        _ => fail("reserved secret environment target accepted")
      }
      assert_true(server.events.is_empty())
    }
    let server = fake_server()
    let report = execute_assignment(
      { ..test_assignment([step]), version: 4, },
      test_options(launcher, workspace),
      (operation, body, until) => server.post(operation, body, until),
      secrets=_ => raise Rejected(403),
    )
    assert_eq(report.conclusion, "failure")
    assert_true(!@fs.exists(workspace + "/executed"))
  })
}
