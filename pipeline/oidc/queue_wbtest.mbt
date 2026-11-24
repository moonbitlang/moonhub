///|
struct SigningFixture {
  runtime : @runtime.Coordinator
  oidc : Service
}

///|
async fn with_signing_fixture(
  f : async (SigningFixture, @database.Database, @runtime.Run) -> Unit,
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let path = root + "/oidc.json"
    @test_support.create_oidc_config(path, "https://issuer.example")
    let issuer = OidcIssuer::load(path)
    let clock = () => 1700000000000L
    let runtime = @runtime.Coordinator::new(pool, clock~)
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, repo)
    ignore(
      runtime.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "oidc",
        provider_secret,
        ["self-hosted", "linux"],
        [repo],
      ),
    )
    let source = @test_support.single_job_workflow +
      "\npermissions:\n  id-token: write\n"
    let definition = @workflow.parse(source)
    let run = pool.with_client(client => {
      client.with_transaction(tx => {
        @runtime.insert_run_snapshot(
          tx,
          scope.id,
          actor.id,
          ".github/workflows/build.yml",
          "OIDC",
          "pipeline",
          "a".repeat(40),
          "refs/moonhub/pipelines/test",
          source,
          definition,
          context=Some({
            repository: "alice/demo",
            sha: "a".repeat(40),
            event_name: "workflow_dispatch",
            head_ref: "",
            base_ref: "",
            inputs: Map([]),
            variables: Map([]),
            release_tag: None,
            event: None,
          }),
        )
      })
    })
    f({ runtime, oidc: Service::new(pool, oidc=issuer, clock~), }, pool, run)
  })
}

///|
async test "OIDC fences cancellation while signing is queued" {
  with_signing_fixture((c, pool, run) => {
    let a = c.runtime.claim(provider_secret, claim_request()).unwrap()
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.runtime.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
    let grant = c.oidc.oidc_runtime(id, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    let issuer = c.oidc.oidc.unwrap()
    for _ in 0..<4 {
      issuer.signing.acquire()
    }
    @async.with_task_group(group => {
      let waiting = group.spawn(() => {
        try ignore(c.oidc.oidc_token(id, grant.token, "")) catch {
          @domain.Unauthorized(_) => ()
          err => raise err
        } noraise {
          _ => fail("issued after queued cancellation")
        }
      })
      @async.sleep(20)
      pool.with_client(client => {
        ignore(
          client.execute(
            "UPDATE pipeline_run SET cancel_requested=1 WHERE id=?",
            params=[run.id],
          ),
        )
      })
      for _ in 0..<4 {
        issuer.signing.release()
      }
      waiting.wait()
    })
  })
}

///|
let provider_secret : String = "a".repeat(64)

///|
let attempt_secret : String = "b".repeat(64)

///|
fn claim_request(
  id~ : String = "1",
  secret~ : String = attempt_secret,
) -> @protocol.ClaimRequest {
  {
    environments: None,
    runner_os: None,
    version: 1,
    request_id: id.repeat(32),
    attempt_token: secret,
  }
}
