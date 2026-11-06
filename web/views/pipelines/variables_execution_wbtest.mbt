///|
async test "real runner consumes captured vars in env conditions Action inputs posts and job outputs" {
  let workflow =
    #|name: Repository variables execution
    #|on: workflow_dispatch
    #|permissions: {}
    #|jobs:
    #|  prepare:
    #|    if: vars.ENABLED == 'true' && vars.MISSING == ''
    #|    runs-on: self-hosted
    #|    outputs:
    #|      region: ${{ vars.OPENSEEK_S3_REGION }}
    #|    steps:
    #|      - env:
    #|          REGION: ${{ vars.openseek_s3_region }}
    #|          LITERAL: ${{ vars.LITERAL }}
    #|        run: |
    #|          test "$REGION" = ap-southeast-1
    #|          test -z "${OPENSEEK_S3_REGION:-}"
    #|          printf '%s' "$LITERAL" | grep -F 'vars.OPENSEEK_S3_REGION'
    #|          mkdir -p local-action
    #|          printf '%s\n' 'inputs: {region: {}}' 'runs: {using: node24, main: main.cjs, post: post.cjs}' > local-action/action.yml
    #|          printf '%s\n' "if(process.env.INPUT_REGION!=='ap-southeast-1')process.exit(23)" > local-action/main.cjs
    #|          printf '%s\n' "require('fs').writeFileSync(process.env.GITHUB_WORKSPACE+'/post-ran',process.env.INPUT_REGION)" > local-action/post.cjs
    #|      - uses: ./local-action
    #|        with:
    #|          region: ${{ vars.OPENSEEK_S3_REGION }}
    #|      - if: vars.ENABLED == 'true'
    #|        env:
    #|          EMPTY: ${{ vars.MISSING }}
    #|        run: test -z "$EMPTY"
    #|  consume:
    #|    needs: prepare
    #|    if: needs.prepare.outputs.region == vars.OPENSEEK_S3_REGION
    #|    runs-on: self-hosted
    #|    steps:
    #|      - env:
    #|          REGION: ${{ needs.prepare.outputs.region }}
    #|        run: test "$REGION" = ap-southeast-1
  let variables : Map[String, String] = {
    "OPENSEEK_S3_REGION": "ap-southeast-1",
    "ENABLED": "true",
    "LITERAL": "${{ vars.OPENSEEK_S3_REGION }}",
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
        // The stored settings can change while already queued jobs retain their copy.
        for variable in @pipeline.list_variables(pool, actor, repo) {
          @pipeline.delete_variable(
            pool,
            actor,
            repo,
            variable.name,
            variable.version,
          )
        }
        let mut assignment = first
        let mut token = lease
        for i = 0; i < 2; i = i + 1 {
          assert_eq(assignment.version, @protocol.variable_assignment_version)
          let workspace = root + "/vars-" + i.to_string()
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
              heartbeat_ms: 50,
            },
            action_node=node.text().trim().to_owned(),
            action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
          )
          if report.conclusion != "success" {
            let logs = c
              .read_logs(
                actor,
                repo,
                @protocol.parse_decimal(first.run_id).unwrap(),
                @protocol.parse_decimal(assignment.attempt_id).unwrap(),
              )
              .map(chunk => chunk.text)
              .join("")
            fail("vars job " + assignment.job.id + ": " + logs)
          }
          assert_true(report.reported)
          if i == 0 {
            assert_eq(
              @fs.read_file(workspace + "/repository/post-ran").text(),
              "ap-southeast-1",
            )
            token = @identity.random_hex(32)
            assignment = c
              .claim("a".repeat(64), {
                version: 1,
                runner_os: None,
                request_id: @identity.random_hex(16),
                attempt_token: token,
              })
              .unwrap()
            assert_eq(assignment.job.id, "consume")
          }
        }
        assert_true(
          @pipeline.list_runs(pool, actor, repo)[0].conclusion
          is Some(@pipeline.Success),
        )
      })
    },
    workflow~,
    variables~,
  )
}
