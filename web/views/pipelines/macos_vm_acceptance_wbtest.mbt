///|
// Opt-in on a dedicated Apple Silicon host; ordinary hosted CI cannot run
// nested VMs. This exercises real HTTP routes, database scheduling and Tart.
async test "macOS VM standby executes real HTTP jobs and replenishes clean capacity" {
  let env = @env.get_env_vars()
  guard env.get("MOONHUB_MACOS_TART") is Some(tart) &&
    env.get("MOONHUB_MACOS_TART_HOME") is Some(home) &&
    env.get("MOONHUB_MACOS_IMAGE") is Some(image) &&
    env.get("MOONHUB_MACOS_HOST") is Some(host) else {
    return
  }
  @test_support.with_repository_test_data((pool, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    let admin = @identity.active_user_by_name(pool, "admin")
    let coordinator = @pipeline.Coordinator::new(pool)
    let registration = @identity.random_hex(32)
    let provider = coordinator.create_provider(
      admin,
      "macos-acceptance",
      registration,
      ["self-hosted", "macos", "arm64"],
      [repo],
    )
    let state = @fs.tmpdir(prefix="moonhub-macos-acceptance-")
    defer @fs.rmdir(state, recursive=true)
    @fs.write_file(state + "/registration", registration, permission=0o600)
    let binary = @fs.realpath(
      "_build/native/debug/build/cmd/moonhub-runner/moonhub-runner.exe",
    )
    let app = @moonback.App(
      Module(ctx => {
        ctx.mount(
          "/-/runner-api/v1",
          App(
            Module(child => {
              child.provide(@web_context.pipeline_coordinator_key, coordinator)
              child.provide(@web_context.config_root, root)
              child.use_(runner_api_module)
            }),
          ),
        )
      }),
    )
    defer app.close()
    @async.with_task_group(group => {
      let listener = @moonback.listen(host="0.0.0.0", port=0)
      let server = group.spawn(() => app.serve(listener))
      defer server.cancel()
      let port = listener.addr.port().to_string()
      let log = @process.redirect_to_file(
        state + "/worker.log",
        permission=0o600,
      )
      let input = @process.redirect_from_file("/dev/null")
      let worker = @process.spawn(
        group,
        binary,
        [
          "run",
          "--mode",
          "tart",
          "--server",
          "http://127.0.0.1:" + port,
          "--runner-server",
          "http://" + host + ":" + port,
          "--allow-http",
          "--name",
          "macos-acceptance",
          "--state-dir",
          state + "/controller",
          "--workspace-root",
          state + "/workspace",
          "--registration-token-file",
          state + "/registration",
          "--tart",
          tart,
          "--tart-home",
          home,
          "--runner-image",
          image,
        ],
        stdin=input,
        stdout=log,
        stderr=log,
      )
      defer worker.cancel()
      async fn standby() -> @protocol.WorkerView {
        @async.with_timeout(240000, () => {
          for ;; {
            guard worker.try_wait() is None else {
              fail(@fs.read_file(state + "/worker.log").text())
            }
            let control = coordinator.provider_control(admin, provider.id)
            if control.snapshot.workers
              .iter()
              .find_first(w => {
                w.state == "ready" &&
                w.applied_revision == control.snapshot.config_revision &&
                !w.draining &&
                w.active_attempts == 0
              })
              is Some(ready) {
              return ready
            }
            @async.sleep(250)
          }
        })
      }
      let first = standby()
      let worker_id = first.id
      for attempt in 1..<=3 {
        let source =
          #|on: workflow_dispatch
          #|jobs:
          #|  mac:
          #|    runs-on: [self-hosted, macos, arm64]
          #|    steps:
          #|      - run: |
          #|          test "$RUNNER_OS" = macOS
          #|          test "$(uname -m)" = arm64
          #|          test "$(id -un)" = _moonhub
          #|          ! id -Gn | grep -qw admin
          #|          ! sudo -n true 2>/dev/null
          #|          test ! -e stale-file
          #|          test -z "${AWS_SECRET_ACCESS_KEY:-}"
          #|          test ! -e "$HOME/stale-home"
          #|          test ! -e "$HOME/Library/Keychains/stale.keychain-db"
          #|          mkdir -p "$HOME/Library/Keychains"
          #|          touch stale-file "$HOME/stale-home" "$HOME/Library/Keychains/stale.keychain-db"
          #|          echo macos-probe-ready
        let source = source +
          (if attempt == 2 {
            "\n          exit 7"
          } else if attempt == 3 {
            "\n          sleep 60"
          } else {
            ""
          })
        ignore(@test_support.workflow_commit(repo.git_dir(root), source))
        let run = @pipeline.create_run(
          pool, root, actor, repo, "pipeline", ".github/workflows/build.yml",
        )
        let begin = @env.now().reinterpret_as_int64()
        let first_log = Ref(0L)
        @async.with_timeout(150000, () => {
          for ;; {
            let job = @pipeline.list_jobs(pool, actor, repo, run.number)[0]
            if job.attempt_id is Some(id) {
              let logs = coordinator.read_log_page(actor, repo, run.number, id).chunks
              if logs.any(chunk => chunk.text.contains("macos-probe-ready")) &&
                first_log.val == 0L {
                first_log.val = @env.now().reinterpret_as_int64() - begin
                if attempt == 3 {
                  coordinator.cancel_run(actor, repo, run.number)
                }
              }
            }
            let current = @pipeline.get_run(pool, actor, repo, run.number)
            if current.state is Completed {
              assert_true(
                if attempt == 1 {
                  current.conclusion is Some(Success)
                } else if attempt == 2 {
                  current.conclusion is Some(Failure)
                } else {
                  current.conclusion is Some(Cancelled)
                },
              )
              break
            }
            guard worker.try_wait() is None else {
              println("job state at worker failure: " + @debug.to_string(job))
              if job.attempt_id is Some(id) {
                println(
                  "step state: " +
                  @debug.to_string(
                    coordinator.read_steps(actor, repo, run.number, id),
                  ),
                )
              }
              fail(@fs.read_file(state + "/worker.log").text())
            }
            @async.sleep(200)
          }
        })
        assert_true(first_log.val > 0L)
        let ready = standby()
        assert_eq(ready.id, worker_id)
        println(
          "macOS VM HTTP acceptance: attempt=" +
          attempt.to_string() +
          " first_command_ms=" +
          first_log.val.to_string(),
        )
      }
      let credential = @fs.read_file(state + "/controller/provider-token")
        .text()
        .trim()
        .to_owned()
      let id = @protocol.parse_decimal(worker_id).unwrap()
      coordinator.drain_worker(credential, id)
      @async.with_timeout(30000, () => {
        for ;; {
          let control = coordinator.provider_control(admin, provider.id)
          if control.snapshot.workers.any(w => {
              w.id == worker_id && w.state == "drained"
            }) {
            break
          }
          @async.sleep(200)
        }
      })
      // A drained worker ends; the local provider/controller keeps its lease.
      assert_true(worker.try_wait() is None)
      println(@fs.read_file(state + "/worker.log").text())
      let (inventory_code, inventory) = @process.collect_output_merged(
        tart,
        ["list", "--source", "local", "--format", "json"],
        inherit_env=false,
        extra_env={
          "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
          "HOME": home,
          "TART_HOME": home,
        },
      )
      assert_eq(inventory_code, 0)
      assert_true(!inventory.text().contains("moonhub-slot-"))
      assert_true(
        !@fs.readdir(home + "/vms").any(name => name.has_prefix("moonhub-slot-")),
      )
    })
  })
}
