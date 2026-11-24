///|
async test "container assignments cannot opt ordinary or unsafe-local runners into Docker" {
  @test_support.with_runner_workspace((_, launcher, workspace) => {
    let base = test_assignment([test_step("check", "touch executed")])
    for
      version in [
        @protocol.run_attempt_assignment_version, @protocol.container_assignment_version,
      ] {
      let assignment = {
        ..base,
        version,
        job: {
          ..base.job,
          context: { "container_plan": "{\"job\":null,\"services\":{}}" },
        },
      }
      for linux_ci in [false, true] {
        let server = fake_server()
        try
          ignore(
            execute_assignment(
              assignment,
              { ..test_options(launcher, workspace), linux_ci, },
              (operation, body, until) => server.post(operation, body, until),
            ),
          )
        catch {
          InvalidConfiguration(_) => ()
          err => raise err
        } noraise {
          _ => fail("unsafe runner accepted container assignment")
        }
        assert_eq(server.execution_id, "")
        assert_true(!@fs.exists(workspace + "/executed"))
      }
    }
  })
}
