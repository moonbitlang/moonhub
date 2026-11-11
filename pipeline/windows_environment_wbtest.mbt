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

///|
async test "Windows environment protocol retains OIDC dispatch and output contracts" {
  let source =
    #|on:
    #|  workflow_dispatch:
    #|    inputs:
    #|      enabled: {type: boolean, default: true}
    #|permissions: {contents: read, id-token: write}
    #|jobs:
    #|  check:
    #|    runs-on: windows-2025
    #|    strategy:
    #|      matrix: {mode: [native]}
    #|    outputs:
    #|      result: ${{ steps.build.outputs.result }}
    #|    steps:
    #|      - id: build
    #|        run: echo check
  with_protocol_fixture(
    (c, pool, _, _, provider, _) => {
      let admin = @identity.active_user_by_name(pool, "admin")
      c.set_provider_labels(admin, provider.id, [
        "self-hosted", "windows", "x64", "windows-2025",
      ])
      let assignment = c
        .claim(provider_secret, {
          ..claim_request(),
          runner_os: Some("windows"),
        })
        .unwrap()
      assert_eq(assignment.version, @protocol.environment_assignment_version)
      assert_true(assignment.job.id_token_write)
      assert_true(assignment.job.contents_read)
      assert_eq(
        assignment.job.dispatch_inputs.get("enabled"),
        Some(Json::boolean(true)),
      )
      assert_eq(
        assignment.job.context.get("event_name"),
        Some("workflow_dispatch"),
      )
      assert_eq(assignment.job.matrix.get("mode"), Some(Json::string("native")))
      assert_eq(
        assignment.job.outputs.get("result"),
        Some("${{ steps.build.outputs.result }}"),
      )
    },
    workflow=source,
  )
}
