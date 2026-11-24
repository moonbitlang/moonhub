///|
async test "real runner carries typed dispatch inputs event files and outputs across jobs" {
  let workflow =
    #|name: Dispatch execution
    #|on:
    #|  workflow_dispatch:
    #|    inputs:
    #|      version: {required: true}
    #|      enabled: {type: boolean, default: false}
    #|      count: {type: number, default: 1}
    #|      literal: {}
    #|permissions: {}
    #|jobs:
    #|  prepare:
    #|    if: inputs.enabled && inputs.count == 3.5
    #|    runs-on: self-hosted
    #|    outputs:
    #|      version: ${{ inputs.version }}
    #|    env:
    #|      VERSION: ${{ inputs.version }}
    #|      ENABLED_JSON: ${{ toJSON(inputs.enabled) }}
    #|      EVENT_ENABLED: ${{ github.event.inputs.enabled }}
    #|      LITERAL: ${{ inputs.literal }}
    #|    steps:
    #|      - run: |
    #|          test "$VERSION" = 1.2.3
    #|          test "$ENABLED_JSON" = true
    #|          test "$EVENT_ENABLED" = true
    #|          test "$LITERAL" = '${{ inputs.enabled }}'
    #|          test -f "$GITHUB_EVENT_PATH"
    #|          grep -F '"enabled":"true"' "$GITHUB_EVENT_PATH"
    #|          printf '{}' > "$GITHUB_EVENT_PATH"
    #|      - if: inputs.enabled
    #|        run: grep -F '"enabled":"true"' "$GITHUB_EVENT_PATH"
    #|  consume:
    #|    needs: prepare
    #|    if: needs.prepare.outputs.version == inputs.version && github.event.inputs.count == '3.5'
    #|    name: consume on ${{ matrix.node.labels['0'] }}
    #|    runs-on: ${{ matrix.node.labels }}
    #|    strategy:
    #|      matrix:
    #|        node: [{version: 20, labels: [self-hosted, linux], flags: [strict, legacy]}]
    #|    steps:
    #|      - id: bounds
    #|        run: printf 'min=2\nmax=4\n' >> "$GITHUB_OUTPUT"
    #|      - id: missing_minimum
    #|        if: matrix.node.minimum < '-1'
    #|        run: exit 99
    #|      - id: verify
    #|        if: inputs.count > fromJSON(steps.bounds.outputs.min) && matrix.node.version >= 20
    #|        env:
    #|          VERSION: ${{ needs.prepare.outputs.version }}
    #|          COUNT_JSON: ${{ toJSON(inputs.count) }}
    #|          EVENT_PATH: ${{ github.event_path }}
    #|          IN_RANGE: ${{ fromJSON(steps.bounds.outputs.min) < inputs.count && inputs.count <= fromJSON(steps.bounds.outputs.max) }}
    #|          LABEL: ${{ matrix.node.labels[0] }}
    #|          MINIMUM: x${{ matrix.node.minimum }}y
    #|          JOINED: ${{ join(fromJSON('[1e16,2]')) }}
    #|          FLAGS: ${{ join(matrix.node.flags, ' | ') }}
    #|          EMPTY: ${{ join(fromJSON('[]')) }}
    #|          SINGLE: ${{ join('abc', '|') }}
    #|          MIXED: ${{ join(fromJSON('[1,true,null]'), '|') }}
    #|        run: |
    #|          test "$VERSION" = 1.2.3
    #|          test "$COUNT_JSON" = 3.5
    #|          test "$EVENT_PATH" = "$GITHUB_EVENT_PATH"
    #|          grep -F '"version":"1.2.3"' "$GITHUB_EVENT_PATH"
    #|          test "$IN_RANGE" = true
    #|          test "$LABEL" = self-hosted
    #|          test "$MINIMUM" = xy
    #|          test "$JOINED" = '1E+16,2'
    #|          test "$FLAGS" = 'strict | legacy'
    #|          test -z "$EMPTY"
    #|          test "$SINGLE" = abc
    #|          test "$MIXED" = '1|true|'
    #|          echo 'result=ok' >> "$GITHUB_OUTPUT"
    #|      - env:
    #|          RESULT: ${{ steps.verify.outputs.result }}
    #|          MISSING_CONCLUSION: ${{ steps.missing_minimum.conclusion }}
    #|        run: |
    #|          test "$RESULT" = ok
    #|          test "$MISSING_CONCLUSION" = skipped
    #|  skipped:
    #|    if: '!inputs.enabled'
    #|    runs-on: self-hosted
    #|    steps: [{run: exit 99}]
  // The literal shell assertion itself must not be treated as a new template.
  let workflow = workflow.replace_all(
    old="test \"$LITERAL\" = '${{ inputs.enabled }}'",
    new="printf '%s' \"$LITERAL\" | grep -F 'inputs.enabled'",
  )
  let inputs : Map[String, Json] = {
    "version": "1.2.3",
    "enabled": true,
    "count": 3.5,
    "literal": "${{ inputs.enabled }}",
  }
  with_artifact_http(
    (port, c, pool, _, first, lease) => {
      @test_support.with_runner_workspace((root, launcher, _) => {
        let (code, node) = @process.collect_output_merged("node", [
          "-p", "process.execPath",
        ])
        assert_eq(code, 0)
        let repo : @domain.RepoId = { owner: "alice", name: "demo", }
        let actor = @identity.active_user_by_name(pool, "alice")
        let mut assignment = first
        let mut token = lease
        for i = 0; i < 2; i = i + 1 {
          assert_eq(
            assignment.version,
            if i == 0 {
              @protocol.variable_assignment_version
            } else {
              @protocol.compatibility_assignment_version
            },
          )
          let workspace = root + "/dispatch-" + i.to_string()
          @fs.mkdir(workspace)
          let report = @runner.run(
            assignment,
            token,
            {
              server: "http://127.0.0.1:\{port}",
              workspace,
              launcher,
              allow_http: true,
              unsafe_local: true,
              linux_ci: false,
              windows_vm: false,
              heartbeat_ms: 50,
            },
            action_node=node.text().trim().to_owned(),
            action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
          )
          if report.conclusion != "success" {
            let logs = c.runtime.read_log_page(
                actor,
                repo,
                @protocol.parse_decimal(first.run_id).unwrap(),
                @protocol.parse_decimal(assignment.attempt_id).unwrap(),
              ).chunks
              .map(chunk => chunk.text)
              .join("")
            fail("dispatch job " + assignment.job.id + ": " + logs)
          }
          assert_true(report.reported)
          if i == 0 {
            token = @identity.random_hex(32)
            assignment = c.runtime
              .claim("a".repeat(64), {
                environments: None,
                version: 1,
                runner_os: None,
                request_id: @identity.random_hex(16),
                attempt_token: token,
              })
              .unwrap()
            assert_eq(assignment.job.id, "consume")
            assert_eq(assignment.job.name, "consume on self-hosted")
            assert_eq(assignment.job.runs_on, ["self-hosted", "linux"])
            assert_eq(
              assignment.job.matrix["node"],
              (
                {
                  "version": 20,
                  "labels": ["self-hosted", "linux"],
                  "flags": ["strict", "legacy"],
                } : Json),
            )
          }
        }
        let runs = @runtime.list_runs(pool, actor, repo)
        assert_eq(runs.length(), 1)
        assert_true(runs[0].conclusion is Some(@runtime.Success))
      })
    },
    workflow~,
    inputs~,
  )
}
