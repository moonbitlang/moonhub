///|
async test "diff cache environment accepts Int64 budgets and rejects invalid values before worker or database startup" {
  // Restore process-wide configuration before yielding to concurrent tests.
  let cases = {
    let names = [
      "MOONHUB_DIFF_CACHE_BYTES", "MOONHUB_DIFF_WORKER", "MOONHUB_DIFF_CONCURRENCY",
      "MOONHUB_DIFF_DEADLINE_MS", "MOONHUB_WEB_MOONDIFF",
    ]
    let previous = names.map(name => (name, @env.get_env_var(name)))
    defer (for (name, value) in previous {
      match value {
        Some(value) => @env.set_env_var(name, value)
        None => @env.unset_env_var(name)
      }
    })
    for name in names {
      @env.unset_env_var(name)
    }
    ignore(diff_executor_from_env())
    for
      value in ["0", "33554432", "4294967296", "9223372036854775807", " 1024 "] {
      @env.set_env_var("MOONHUB_DIFF_CACHE_BYTES", value)
      ignore(diff_executor_from_env())
    }
    // An invalid cache setting must win over worker verification and DB setup.
    @env.set_env_var("MOONHUB_DIFF_WORKER", "/missing-moonhub-diff-worker")
    let config : Config = {
      root: "/missing-moonhub-test-repositories",
      assets_root: "/missing-moonhub-test-assets",
      host: "127.0.0.1",
      port: 0,
      root_user: { name_key: "root", initial_password: "", },
    }
    for enabled in ["true", "false"] {
      @env.set_env_var("MOONHUB_WEB_MOONDIFF", enabled)
      for
        value in [
          "", " ", "abc", "1.5", "32MiB", "-1", "9223372036854775808", "-9223372036854775809",
        ] {
        @env.set_env_var("MOONHUB_DIFF_CACHE_BYTES", value)
        try serve(config) catch {
          @domain.BadRequest(message~) =>
            assert_eq(
              message, "MOONHUB_DIFF_CACHE_BYTES must be a non-negative Int64 byte count",
            )
          err => raise err
        } noraise {
          _ => fail("accepted invalid cache configuration")
        }
      }
    }
    ["0", "33554432"].map(limit => {
      @env.set_env_var("MOONHUB_DIFF_CACHE_BYTES", limit)
      let events : Array[Json] = []
      let executor = diff_executor_from_env(observe=event => events.push(event))
      (limit, executor, events)
    })
  }
  @test_support.with_repository_test_data((_pool, root) => {
    let dir = "\{root}/alice/demo.git"
    let sha = @gitops.branch_sha(dir, "master")
    for (limit, executor, events) in cases {
      ignore(executor.manifest(dir, sha, sha))
      ignore(executor.manifest(dir, sha, sha))
      assert_eq(executor.completed, if limit == "0" { 2 } else { 1 })
      assert_true(
        events[0] is { "cache_limit_bytes": String(actual), .. } &&
        actual == limit,
      )
    }
  })
}
