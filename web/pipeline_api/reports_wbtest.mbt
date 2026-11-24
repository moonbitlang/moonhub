///|
let report_test_workflow : String =
  #|name: Reports
  #|on: workflow_dispatch
  #|jobs:
  #|  report:
  #|    runs-on: [self-hosted, linux]
  #|    steps:
  #|      - id: first
  #|        run: |
  #|          printf '::add-mask::report-secret\n'
  #|          printf '## First summary\nreport-secret\n<script>alert(1)</script>\n[bad](javascript:alert)\n' >> "$GITHUB_STEP_SUMMARY"
  #|          printf '::error file=src/main.mbt,line=12,endLine=14,col=8,endColumn=5,title=Problem::report-secret <script>alert(2)</script>\n'
  #|      - id: second
  #|        run: |
  #|          printf '## Second summary\nAll done\n' >> "$GITHUB_STEP_SUMMARY"
  #|          printf '::notice::completed successfully\n'

///|
async test "native reports persist combined summaries and annotations with safe authorized run rendering" {
  @web_testkit.with_repository_test_app((port, pool, root, alice, bob) => {
    @test_support.with_runner_workspace((_, launcher, workspace) => {
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let actor = @identity.active_user_by_name(pool, "alice")
      ignore(
        @test_support.workflow_commit(repo.git_dir(root), report_test_workflow),
      )
      let run = @pipeline.create_run(
        pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
      )
      let c = @runtime.Coordinator::new(pool)
      ignore(
        c.create_provider(
          @identity.active_user_by_name(pool, "admin"),
          "reports",
          "a".repeat(64),
          ["self-hosted", "linux"],
          [repo],
        ),
      )
      let lease = "b".repeat(64)
      let a = c
        .claim("a".repeat(64), {
          version: 1,
          request_id: "c".repeat(32),
          attempt_token: lease,
          runner_os: None,
          environments: None,
        })
        .unwrap()
      assert_eq(a.version, @protocol.report_assignment_version)
      let (code, node) = @process.collect_output_merged("node", [
        "-p", "process.execPath",
      ])
      assert_eq(code, 0)
      let result = @runner.run(
        a,
        lease,
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
      assert_eq(
        result.conclusion,
        "success",
        msg=ToJson::to_json(result).stringify(),
      )
      let report = @runtime.Coordinator::new(pool).read_report(
        actor,
        repo,
        run.number,
        @protocol.parse_decimal(a.attempt_id).unwrap(),
      )
      assert_eq(report.entries.length(), 2)
      assert_true(report.entries[0].summary.contains("## First summary"))
      assert_true(report.entries[1].summary.contains("## Second summary"))
      assert_false(
        ToJson::to_json(report).stringify().contains("report-secret"),
      )
      assert_eq(report.entries[0].annotations[0].severity, "error")
      assert_eq(report.entries[0].annotations[0].end_line, 14)
      let path = "/alice/demo/pipelines/" + run.number.to_string()
      let (response, body) = @web_testkit.http_get_path_with_cookie(
        port, path, alice,
      )
      assert_eq(response.code, 200)
      assert_true(body.contains("Step summary"))
      assert_true(body.contains("Second summary"))
      assert_true(body.contains("src/main.mbt"))
      assert_true(body.contains("line 12–14"))
      assert_true(body.contains("column 8–5"))
      assert_true(body.contains("data-annotation-severity=\"error\""))
      assert_false(body.contains("<script>alert("))
      assert_false(body.contains("href=\"javascript:"))
      assert_false(body.contains("report-secret"))
      assert_eq(
        @web_testkit.http_get_path_with_cookie(port, path, bob).0.code,
        404,
      )
      let rerun = @pipeline.rerun_run(pool, root, actor, repo, run.number)
      assert_eq(
        @runtime.Coordinator::new(pool).read_report(
          actor,
          repo,
          run.number,
          @protocol.parse_decimal(a.attempt_id).unwrap(),
        ),
        report,
      )
      let (_, body) = @web_testkit.http_get_path_with_cookie(
        port,
        "/alice/demo/pipelines/" + rerun.number.to_string(),
        alice,
      )
      assert_false(body.contains("First summary"))
    })
  })
}

///|
async test "report transport checks revision idempotency live scope locations quotas and server masks" {
  with_artifact_http(
    (port, c, pool, _, a, lease) => {
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      let execution = "e".repeat(32)
      ignore(c.runtime.start(id, lease, 1, execution_id=execution))
      ignore(
        c.runtime.update_step(id, lease, {
          version: 1,
          step_id: "first",
          state: "running",
          exit_code: 0,
        }),
      )
      pool.with_client(client => {
        ignore(
          client.execute(
            "INSERT INTO pipeline_secret_delivery(attempt_id,step_id,env_name,value) VALUES(?,?,?,?)",
            params=[id, "first", "SECRET", "report-secret"],
          ),
        )
      })
      let annotation : @protocol.Annotation = {
        severity: "error",
        message: "<b>report-secret</b>",
        title: "title",
        file: "src/main.mbt",
        line: 1,
        end_line: 1,
        column: 0,
        end_column: 0,
      }
      let report : @protocol.JobReport = {
        revision: 1,
        truncated: false,
        entries: [
          {
            step_id: "first",
            summary: "report-secret " + lease + "\n" + "x".repeat(70000),
            annotations: [annotation],
          },
        ],
      }
      let request : @protocol.ReportRequest = {
        version: 1,
        execution_id: execution,
        report,
      }
      let path = "/attempts/" + a.attempt_id + "/reports"
      for _ in 0..<2 {
        assert_eq(
          @web_testkit.runner_post_json(
            port,
            path,
            ToJson::to_json(request).stringify(),
            token=lease,
          ).0,
          200,
        )
      }
      let actor = @identity.active_user_by_name(pool, "alice")
      let stored = c.runtime.read_report(
        actor,
        { owner: "alice", name: "demo", },
        1L,
        id,
      )
      assert_false(ToJson::to_json(stored).stringify().contains(lease))
      assert_false(
        ToJson::to_json(stored).stringify().contains("report-secret"),
      )
      let changed = { ..request, report: { ..report, truncated: true, }, }
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          path,
          ToJson::to_json(changed).stringify(),
          token=lease,
        ).0,
        409,
      )
      for
        invalid in [
          {
            ..report,
            revision: 2,
            entries: [{ ..report.entries[0], step_id: "unknown", }],
          },
          {
            ..report,
            revision: 2,
            entries: [{ ..report.entries[0], step_id: "second", }],
          },
          {
            ..report,
            revision: 2,
            entries: [{ ..report.entries[0], summary: "x".repeat(1048577), }],
          },
          {
            ..report,
            revision: 2,
            entries: [
              {
                ..report.entries[0],
                annotations: [{ ..annotation, line: 2, end_line: 1, }],
              },
            ],
          },
        ] {
        assert_eq(
          @web_testkit.runner_post_json(
            port,
            path,
            ToJson::to_json({ ..request, report: invalid, }).stringify(),
            token=lease,
          ).0,
          400,
        )
      }
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          path,
          ToJson::to_json({ ..request, execution_id: "f".repeat(32), }).stringify(),
          token=lease,
        ).0,
        401,
      )
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          path,
          ToJson::to_json(request).stringify(),
          token="f".repeat(64),
        ).0,
        401,
      )
      c.runtime.cancel_run(actor, { owner: "alice", name: "demo", }, 1L)
      assert_eq(
        @web_testkit.runner_post_json(
          port,
          path,
          ToJson::to_json({ ..request, report: { ..report, revision: 2, }, }).stringify(),
          token=lease,
        ).0,
        401,
      )
      assert_eq(
        c.runtime.read_report(actor, { owner: "alice", name: "demo", }, 1L, id),
        stored,
      )
    },
    workflow=report_test_workflow,
  )
}

///|
async test "server report masking preserves byte limits and truncates later content" {
  with_artifact_http(
    (_, c, pool, _, a, lease) => {
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      let execution = "e".repeat(32)
      ignore(c.runtime.start(id, lease, 1, execution_id=execution))
      ignore(
        c.runtime.update_step(id, lease, {
          version: 1,
          step_id: "first",
          state: "running",
          exit_code: 0,
        }),
      )
      ignore(
        c.runtime.update_step(id, lease, {
          version: 1,
          step_id: "first",
          state: "success",
          exit_code: 0,
        }),
      )
      ignore(
        c.runtime.update_step(id, lease, {
          version: 1,
          step_id: "second",
          state: "running",
          exit_code: 0,
        }),
      )
      pool.with_client(client => {
        ignore(
          client.execute(
            "INSERT INTO pipeline_secret_delivery(attempt_id,step_id,env_name,value) VALUES(?,?,?,?)",
            params=[id, "first", "SECRET", "x\ny"],
          ),
        )
      })
      let item : @protocol.Annotation = {
        severity: "notice",
        message: "x" + "m".repeat(16383),
        title: "x" + "界".repeat(66) + ".",
        file: "x" + "f".repeat(1023),
        line: 0,
        end_line: 0,
        column: 0,
        end_column: 0,
      }
      let report : @protocol.JobReport = {
        revision: 1,
        truncated: false,
        entries: [
          {
            step_id: "first",
            summary: "x" + "界".repeat(349524),
            annotations: [item],
          },
          { step_id: "second", summary: "abc", annotations: [], },
        ],
      }
      let request : @protocol.ReportRequest = {
        version: 1,
        execution_id: execution,
        report,
      }
      for _ in 0..<2 {
        ignore(c.runtime.write_report(id, lease, request))
      }
      let actor = @identity.active_user_by_name(pool, "alice")
      let repo : @domain.RepoId = { owner: "alice", name: "demo", }
      let saved = c.runtime.read_report(actor, repo, 1L, id)
      assert_true(saved.truncated)
      assert_eq(saved.entries[0].summary, "***" + "界".repeat(349524))
      assert_eq(saved.entries[1].summary, "a")
      assert_eq(
        saved.entries[0].annotations[0].message,
        "***" + "m".repeat(16381),
      )
      assert_eq(saved.entries[0].annotations[0].title, "***" + "界".repeat(65))
      assert_eq(saved.entries[0].annotations[0].file, "***" + "f".repeat(1021))
      let overhead = @utf8.encode(
        ToJson::to_json({ ..item, message: "", title: "", file: "", }).stringify(),
      ).length()
      let full = {
        ..item,
        message: "x " + "m".repeat(16384 - overhead - 2),
        title: "",
        file: "",
      }
      ignore(
        c.runtime.write_report(id, lease, {
          ..request,
          report: {
            ..report,
            revision: 2,
            entries: [
              {
                step_id: "first",
                summary: "",
                annotations: Array::make(16, full),
              },
            ],
          },
        }),
      )
      let saved = c.runtime.read_report(actor, repo, 1L, id)
      assert_true(saved.truncated)
      assert_eq(saved.entries[0].annotations.length(), 15)
      assert_true(
        saved.entries[0].annotations.fold(init=0, (size, a) => {
          size + @utf8.encode(ToJson::to_json(a).stringify()).length()
        }) <=
        262144,
      )
    },
    workflow=report_test_workflow,
  )
}
