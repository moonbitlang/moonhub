///|
let named_check_workflow : String =
  #|name: selected results
  #|on: pull_request
  #|permissions: {checks: write}
  #|jobs:
  #|  required:
  #|    name: Required tests
  #|    runs-on: [self-hosted, linux]
  #|    steps: [{id: check, run: echo checked}]
  #|  optional:
  #|    name: Optional tests
  #|    runs-on: [self-hosted, linux]
  #|    steps: [{id: check, run: exit 1}]

///|
async test "named merge results ignore optional failures but block missing ambiguous and obsolete candidates" {
  for mode in ["job", "missing", "duplicate-job", "check", "duplicate-check"] {
    with_merge_check_fixture(
      (pool, root, scope, actor, mr) => {
        let kind = if mode.contains("check") { "check" } else { "job" }
        let name = if kind == "check" {
          "coverage"
        } else if mode == "missing" {
          "Absent"
        } else {
          "Required tests"
        }
        let selector = ".github/workflows/build.yml::" + kind + "::" + name
        @collaboration.save_branch_rule(
          pool,
          scope,
          protocol_repo.git_dir(root),
          actor,
          "master",
          true,
          0L,
          checks=[selector],
        )
        assert_eq(@collaboration.required_merge_checks(pool, scope, "master"), [
          selector,
        ])
        @collaboration.approve_merge_checks(pool, scope, actor, mr, mr.version)
        poll_merge_checks(pool, root)
        let c = merge_check_provider(pool)
        for _ in 0..<2 {
          let (a, lease) = claim_dag_attempt(c, provider_secret)
          let id = @protocol.parse_decimal(a.attempt_id).unwrap()
          ignore(c.runtime.start(id, lease, 1, execution_id="a".repeat(32)))
          if kind == "check" && a.job.id == "required" {
            let token = c.runtime.api_runtime(id, lease, {
                version: 1,
                execution_id: "a".repeat(32),
              }).token
            let count = if mode == "duplicate-check" { 2 } else { 1 }
            for _ in 0..<count {
              ignore(
                c.runtime.write_check_run(token, protocol_repo, {
                  "name": "coverage",
                  "head_sha": a.commit_sha,
                  "conclusion": "success",
                }),
              )
            }
            assert_true(
              @collaboration.merge_blocker(
                pool,
                scope,
                mr,
                @collaboration.merge_revision(pool, mr),
              ).contains("has not passed") ||
              mode == "duplicate-check",
            )
          }
          let result = if a.job.id == "required" {
            "success"
          } else {
            "failure"
          }
          for state in ["running", result] {
            ignore(
              c.runtime.update_step(id, lease, {
                version: 1,
                step_id: "check",
                state,
                exit_code: if result == "success" {
                  0
                } else {
                  1
                },
              }),
            )
          }
          ignore(c.runtime.complete(id, lease, completion(conclusion=result)))
        }
        let blocker = @collaboration.merge_blocker(
          pool,
          scope,
          mr,
          @collaboration.merge_revision(pool, mr),
        )
        if mode == "missing" {
          assert_true(blocker.contains("missing"), msg=blocker)
        } else if mode.has_prefix("duplicate") {
          assert_true(blocker.contains("ambiguous"), msg=blocker)
        } else {
          assert_eq(blocker, "")
          let dir = protocol_repo.git_dir(root)
          ignore(
            merge_check_commit(
              dir,
              "feature",
              @gitops.branch_sha(dir, "feature"),
              "new candidate\n",
            ),
          )
          poll_merge_checks(pool, root)
          let current = @collaboration.require_merge_request(
            pool,
            scope,
            mr.number,
          )
          assert_true(current.version > mr.version)
          assert_false(
            @collaboration.merge_blocker(
              pool,
              scope,
              current,
              @collaboration.merge_revision(pool, current),
            ).is_empty(),
          )
        }
      },
      workflow=if mode == "duplicate-job" {
        named_check_workflow.replace_all(
          old="Optional tests",
          new="Required tests",
        )
      } else {
        named_check_workflow
      },
      required=false,
    )
  }
}
