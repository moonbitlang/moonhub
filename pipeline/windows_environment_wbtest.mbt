///|
async test "Windows latest snapshot claims only matching 2025 providers and requires environment protocol" {
  let source =
    #|on: workflow_dispatch
    #|jobs:
    #|  check:
    #|    runs-on: windows-latest
    #|    steps: [{run: echo check}]
  with_protocol_fixture(
    (c, pool, _, run, provider, _) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      let request = { ..claim_request(), runner_os: Some("windows"), }
      c.set_provider_labels(admin, provider.id, [
        "self-hosted", "windows", "x64", "windows-2022",
      ])
      assert_true(c.claim(provider_secret, request) is None)
      c.set_provider_labels(admin, provider.id, [
        "self-hosted", "windows", "x64", "windows-2025",
      ])
      let assignment = c.claim(provider_secret, request).unwrap()
      assert_eq(assignment.version, @protocol.environment_assignment_version)
      assert_eq(assignment.job.runs_on, [
        "self-hosted", "windows", "x64", "windows-2025",
      ])
      assert_eq(run.definition.jobs[0].runs_on, assignment.job.runs_on)
      assert_true(run.workflow_source.contains("windows-latest"))
    },
    workflow=source,
  )
}
