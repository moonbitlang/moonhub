///|
// Always runs shell/native/HTTP dataflow. The opt-in additionally downloads and
// executes the pinned upstream Artifact v4 Actions across actual runner jobs.
async test "real runner carries version outputs through conditional matrix builds and artifact jobs" {
  let upstream = @env.get_env_vars().get("MOONHUB_DATAFLOW_UPSTREAM") ==
    Some("1")
  let workflow =
    #|name: Job dataflow acceptance
    #|on: workflow_dispatch
    #|permissions: {}
    #|jobs:
    #|  prepare:
    #|    runs-on: self-hosted
    #|    outputs:
    #|      version: ${{ steps.version.outputs.version }}
    #|      publish: ${{ steps.version.outputs.publish }}
    #|      secret: ${{ steps.version.outputs.secret }}
    #|    steps:
    #|      - id: version
    #|        run: |
    #|          echo version=1.2.3 >> "$GITHUB_OUTPUT"
    #|          echo publish=true >> "$GITHUB_OUTPUT"
    #|          echo secret=must-stay-private >> "$GITHUB_OUTPUT"
    #|          echo ::add-mask::must-stay-private
    #|  build:
    #|    needs: prepare
    #|    if: needs.prepare.outputs.publish == 'true'
    #|    strategy: {matrix: {target: [linux, macos]}}
    #|    runs-on: self-hosted
    #|    env:
    #|      VERSION: ${{ needs.prepare.outputs.version }}
    #|    outputs:
    #|      artifact: ${{ steps.build.outputs.name }}
    #|    steps:
    #|      - id: build
    #|        env:
    #|          TARGET: ${{ matrix.target }}
    #|        run: |
    #|          test "$VERSION" = 1.2.3
    #|          printf '%s\n' "$VERSION-$TARGET" > artifact.txt
    #|          echo "name=$VERSION-$TARGET" >> "$GITHUB_OUTPUT"
    #|      # UPLOAD
    #|  consume:
    #|    needs: [prepare, build]
    #|    if: success() && needs.prepare.outputs.version == '1.2.3'
    #|    runs-on: self-hosted
    #|    steps:
    #|      # DOWNLOAD
    #|      - env:
    #|          ARTIFACT: ${{ needs.build.outputs.artifact }}
    #|          PRIVATE: ${{ needs.prepare.outputs.secret }}
    #|        run: |
    #|          test "$ARTIFACT" = 1.2.3-macos
    #|          test -z "$PRIVATE"
    #|          # VERIFY
    #|  skipped:
    #|    needs: prepare
    #|    if: needs.prepare.outputs.publish == 'false'
    #|    runs-on: self-hosted
    #|    steps: [{run: exit 99}]
  let workflow = if upstream {
    workflow
    .replace_all(
      old="# UPLOAD",
      new=(
        #|- uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
        #|        with:
        #|          name: ${{ steps.build.outputs.name }}
        #|          path: artifact.txt
        #|          if-no-files-found: error
      ),
    )
    .replace_all(
      old="# DOWNLOAD",
      new=(
        #|- uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093
        #|        with:
        #|          pattern: ${{ needs.prepare.outputs.version }}-*
        #|          path: downloaded
      ),
    )
    .replace_all(
      old="# VERIFY",
      new="grep -q 1.2.3-linux downloaded/1.2.3-linux/artifact.txt; grep -q 1.2.3-macos downloaded/1.2.3-macos/artifact.txt",
    )
  } else {
    workflow
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
        for index = 0; index < 4; index = index + 1 {
          let workspace = root + "/job-" + index.to_string()
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
            action_node20=@env.get_env_vars()
              .get("MOONHUB_ARTIFACT_NODE20")
              .unwrap_or(node.text().trim().to_owned()),
            action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
          )
          if report.conclusion != "success" {
            let logs = c.read_log_page(
                actor,
                repo,
                @protocol.parse_decimal(first.run_id).unwrap(),
                @protocol.parse_decimal(assignment.attempt_id).unwrap(),
              ).chunks
              .map(chunk => chunk.text)
              .join("")
            fail("runner job " + assignment.job.id + ": " + logs)
          }
          assert_true(report.reported)
          if index < 3 {
            token = @identity.random_hex(32)
            assignment = c
              .claim("a".repeat(64), {
                version: 1,
                runner_os: None,
                request_id: @identity.random_hex(16),
                attempt_token: token,
              })
              .unwrap()
            if index == 2 {
              assert_eq(assignment.job.id, "consume")
            }
          }
        }
        let runs = @pipeline.list_runs(pool, actor, repo)
        assert_eq(runs.length(), 1)
        assert_true(runs[0].conclusion is Some(@pipeline.Success))
        assert_true(
          @pipeline.list_jobs(pool, actor, repo, runs[0].number)
          .iter()
          .find_first(job => job.job_key == "skipped")
          .unwrap().conclusion
          is Some(@pipeline.Skipped),
        )
        assert_true(
          c.claim("a".repeat(64), {
            version: 1,
            runner_os: None,
            request_id: @identity.random_hex(16),
            attempt_token: @identity.random_hex(32),
          })
          is None,
        )
      })
    },
    workflow~,
  )
}

///|
async test "real runner terminates a job after the shared output budget rejects completion" {
  let workflow =
    #|on: workflow_dispatch
    #|permissions: {}
    #|jobs:
    #|  produce:
    #|    strategy: {fail-fast: false, matrix: {index: [0,1,2,3,4,5,6,7,8]}}
    #|    runs-on: self-hosted
    #|    outputs:
    #|      first: FIRST_OUTPUT
    #|      second: SECOND_OUTPUT
    #|    steps:
    #|      - id: produce
    #|        run: printf x >> executed
  let workflow = workflow
    .replace_all(old="FIRST_OUTPUT", new="x".repeat(16300))
    .replace_all(old="SECOND_OUTPUT", new="y".repeat(16300))
  with_artifact_http(
    (port, c, pool, _, first, lease) => {
      let mut assignment = first
      let mut token = lease
      for index = 0; index < 8; index = index + 1 {
        let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
        ignore(c.start(id, token, 1, execution_id="e".repeat(32)))
        ignore(
          c.update_step(id, token, {
            version: 1,
            step_id: "produce",
            state: "running",
            exit_code: 0,
          }),
        )
        ignore(
          c.update_step(id, token, {
            version: 1,
            step_id: "produce",
            state: "success",
            exit_code: 0,
          }),
        )
        let request : @protocol.CompleteRequest = {
          version: 1,
          conclusion: "success",
          last_log_sequence: "0",
          outputs: { "first": "x".repeat(16300), "second": "y".repeat(16300) },
        }
        assert_eq(c.complete(id, token, request).conclusion, "success")
        token = @identity.random_hex(32)
        assignment = c
          .claim("a".repeat(64), {
            version: 1,
            runner_os: None,
            request_id: @identity.random_hex(16),
            attempt_token: token,
          })
          .unwrap()
      }
      @test_support.with_runner_workspace((_, launcher, workspace) => {
        let (code, node) = @process.collect_output_merged("node", [
          "-p", "process.execPath",
        ])
        assert_eq(code, 0)
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
        assert_eq(report.conclusion, "failure")
        assert_true(report.reported)
        assert_eq(@fs.read_file(workspace + "/repository/executed").text(), "x")
      })
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let actor = @identity.active_user_by_name(pool, "alice")
      let runs = @pipeline.list_runs(pool, actor, repo)
      assert_true(runs[0].state is @pipeline.Completed)
      assert_true(runs[0].conclusion is Some(@pipeline.Failure))
      let logs = c.read_log_page(
          actor,
          repo,
          runs[0].number,
          @protocol.parse_decimal(assignment.attempt_id).unwrap(),
        ).chunks
        .map(chunk => chunk.text)
        .join("")
      if !logs.contains("coordinator rejected job outputs") {
        fail(logs)
      }
      pool.with_client(client => {
        assert_eq(
          (
            client
            .query_one("SELECT COUNT(*) AS n FROM pipeline_job_output")
            .get_name("n") : Int64),
          8L,
        )
      })
    },
    workflow~,
  )
}
