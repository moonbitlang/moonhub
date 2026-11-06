///|
let secret_workflow : String =
  #|on: workflow_dispatch
  #|jobs:
  #|  build:
  #|    runs-on: [self-hosted, linux]
  #|    steps:
  #|      - id: check
  #|        env:
  #|          CREDENTIALS: ${{ secrets.publish_token }}
  #|        run: printf '%s' "$CREDENTIALS"

///|
let credentials_fixture : String = "{\"username\":\"private-user\",\"token\":\"private-token-value\"}"

///|
async fn with_secret_fixture(
  f : async (@database.Database, String, Coordinator, Run) -> Unit,
  two_steps~ : Bool = false,
) -> Unit {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    ignore(
      @test_support.workflow_commit(
        protocol_repo.git_dir(root),
        if two_steps {
          secret_workflow +
          "\n      - id: later\n        env: {CREDENTIALS: '${{ secrets.PUBLISH_TOKEN }}'}\n        run: 'true'"
        } else {
          secret_workflow
        },
      ),
    )
    save_secret(
      pool,
      root,
      actor,
      protocol_repo,
      "publish_token",
      Some(credentials_fixture),
      "pipeline",
      ".github/workflows/build.yml",
      0L,
    )
    let run = create_run(
      pool, root, actor, protocol_repo, "pipeline", ".github/workflows/build.yml",
    )
    let coordinator = Coordinator::new(pool)
    ignore(
      coordinator.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "secrets",
        provider_secret,
        ["self-hosted", "linux"],
        [protocol_repo],
      ),
    )
    f(pool, root, coordinator, run)
  })
}

///|
async test "repository secrets require managers validate inputs and survive deletion without stale revision reuse" {
  with_secret_fixture((pool, root, _, run) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let metadata = list_secrets(pool, actor, protocol_repo)[0]
    assert_eq(metadata.name, "PUBLISH_TOKEN")
    assert_true(
      !Debug::to_repr(metadata).to_string().contains("private-token-value"),
    )
    let bob = @identity.active_user_by_name(pool, "bob")
    try ignore(list_secrets(pool, bob, protocol_repo)) catch {
      @domain.NotFound(_) | @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("outsider listed secrets")
    }
    for
      name in [
        "1TOKEN", "bad-name", "GITHUB_TOKEN", "RUNNER_TOKEN", "MOONHUB_TOKEN",
      ] {
      try
        save_secret(
          pool,
          root,
          actor,
          protocol_repo,
          name,
          Some("value"),
          "pipeline",
          ".github/workflows/build.yml",
          0L,
        )
      catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid secret name")
      }
    }
    for value in ["", "a\u{0000}b", "x".repeat(16385)] {
      try
        save_secret(
          pool,
          root,
          actor,
          protocol_repo,
          "BAD",
          Some(value),
          "pipeline",
          ".github/workflows/build.yml",
          0L,
        )
      catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid secret value")
      }
    }
    try
      save_secret(
        pool,
        root,
        actor,
        protocol_repo,
        metadata.name,
        Some("stale"),
        "pipeline",
        metadata.workflow_path,
        0L,
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale save overwrote secret")
    }
    save_secret(
      pool,
      root,
      actor,
      protocol_repo,
      metadata.name,
      None,
      "pipeline",
      metadata.workflow_path,
      metadata.version,
    )
    let updated = list_secrets(pool, actor, protocol_repo)[0]
    assert_true(updated.version > metadata.version)
    pool.with_client(client => {
      assert_eq(
        (
          client
          .query_one("SELECT value FROM repository_secret")
          .get_name("value") : String),
        credentials_fixture,
      )
      assert_eq(
        (
          client
          .query_one("SELECT definition_json FROM pipeline_run WHERE id = ?", params=[
            run.id,
          ])
          .get_name("definition_json") : String).contains(credentials_fixture),
        false,
      )
      for
        row in client.query_all(
          "SELECT detail FROM repository_audit WHERE kind LIKE 'secret_%'",
        ) {
        assert_true(!(row.get_name("detail") : String).contains("private"))
      }
    })
    delete_secret(pool, actor, protocol_repo, metadata.name, updated.version)
    save_secret(
      pool,
      root,
      actor,
      protocol_repo,
      metadata.name,
      Some("new-value"),
      "pipeline",
      metadata.workflow_path,
      0L,
    )
    let recreated = list_secrets(pool, actor, protocol_repo)[0]
    assert_true(recreated.version > updated.version)
    try
      delete_secret(pool, actor, protocol_repo, metadata.name, updated.version)
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("stale delete removed recreated secret")
    }
  })
}

///|
async test "secret policy rejects different branches workflows and MR contexts before snapshot insertion" {
  with_secret_fixture((pool, root, _, run) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    ignore(
      @gitops.merge_git(protocol_repo.git_dir(root), [
        "update-ref",
        "refs/heads/untrusted",
        run.commit_sha,
      ]),
    )
    try
      ignore(
        create_run(
          pool,
          root,
          actor,
          protocol_repo,
          "untrusted",
          run.workflow_path,
        ),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("untrusted branch used a secret")
    }
    let repo_id = run.repository_id
    for event in ["pull_request", "release", "unknown"] {
      try
        pool.with_client(client => {
          client.with_transaction(tx => {
            validate_secret_policy(
              tx,
              repo_id,
              "pipeline",
              run.workflow_path,
              Some({
                repository: "alice/demo",
                sha: run.commit_sha,
                event_name: event,
                head_ref: "",
                base_ref: "",
                inputs: Map([]),
              }),
              run.definition,
            )
          })
        })
      catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("unsupported event gained secret access")
      }
    }
    let secret = list_secrets(pool, actor, protocol_repo)[0]
    save_secret(
      pool,
      root,
      actor,
      protocol_repo,
      secret.name,
      None,
      "pipeline",
      ".github/workflows/other.yml",
      secret.version,
    )
    try
      ignore(
        create_run(
          pool,
          root,
          actor,
          protocol_repo,
          "pipeline",
          run.workflow_path,
        ),
      )
    catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("wrong workflow used a secret")
    }
  })
}

///|
async test "step secret delivery binds execution and step masks issued values across rotation deletion and chunks" {
  with_secret_fixture((pool, root, coordinator, run) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let assignment = coordinator
      .claim(provider_secret, claim_request())
      .unwrap()
    assert_eq(assignment.version, @protocol.dispatch_assignment_version)
    assert_true(
      !assignment.to_json().stringify().contains("private-token-value"),
    )
    assert_eq(
      assignment.job.steps[0].secret_env.get("CREDENTIALS"),
      Some("PUBLISH_TOKEN"),
    )
    let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
    let request : @protocol.SecretRequest = {
      version: 1,
      execution_id: "c".repeat(32),
      step_id: "check",
    }
    try ignore(coordinator.step_secrets(id, attempt_secret, request)) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("leased attempt fetched secrets")
    }
    ignore(
      coordinator.start(
        id,
        attempt_secret,
        1,
        execution_id=request.execution_id,
      ),
    )
    try ignore(coordinator.step_secrets(id, attempt_secret, request)) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("pending step fetched secrets")
    }
    ignore(
      coordinator.update_step(id, attempt_secret, {
        version: 1,
        step_id: "check",
        state: "running",
        exit_code: 0,
      }),
    )
    try ignore(coordinator.step_secrets(id, provider_secret, request)) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("provider credential fetched secrets")
    }
    try
      ignore(
        coordinator.step_secrets(id, attempt_secret, {
          ..request,
          execution_id: "d".repeat(32),
        }),
      )
    catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("wrong execution fetched secrets")
    }
    assert_eq(
      coordinator.step_secrets(id, attempt_secret, request).env.get(
        "CREDENTIALS",
      ),
      Some(credentials_fixture),
    )
    let secret = list_secrets(pool, actor, protocol_repo)[0]
    save_secret(
      pool,
      root,
      actor,
      protocol_repo,
      secret.name,
      Some("replacement-token"),
      "pipeline",
      run.workflow_path,
      secret.version,
    )
    assert_eq(
      coordinator.step_secrets(id, attempt_secret, request).env.get(
        "CREDENTIALS",
      ),
      Some(credentials_fixture),
    )
    ignore(
      coordinator.append_log(
        id,
        attempt_secret,
        log_request(1L, "credential=" + credentials_fixture[:30].to_owned()),
      ),
    )
    ignore(
      coordinator.append_log(
        id,
        attempt_secret,
        log_request(
          2L,
          credentials_fixture[30:].to_owned() + "\ntoken=private-token-",
        ),
      ),
    )
    let secret = list_secrets(pool, actor, protocol_repo)[0]
    delete_secret(pool, actor, protocol_repo, secret.name, secret.version)
    ignore(
      coordinator.append_log(
        id,
        attempt_secret,
        log_request(3L, "value\ntruncated=private-tok"),
      ),
    )
    try ignore(coordinator.step_secrets(id, attempt_secret, request)) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("deleted secret was issued again")
    }
    ignore(
      coordinator.complete(
        id,
        attempt_secret,
        completion(conclusion="failure", last=3L),
      ),
    )
    let logs = coordinator
      .read_logs(actor, protocol_repo, run.number, id)
      .map(chunk => chunk.text)
      .join("")
    assert_eq(logs, "credential=***\ntoken=***\ntruncated=***")
    pool.with_client(client => {
      assert_true(
        client.query_all("SELECT * FROM pipeline_secret_delivery").is_empty(),
      )
      for row in client.query_all("SELECT content FROM pipeline_log_chunk") {
        assert_true(
          !(row.get_name("content") : String).contains("private-token"),
        )
      }
    })
    try ignore(rerun_run(pool, root, actor, protocol_repo, run.number)) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("rerun bypassed deleted secret policy")
    }
  })
}

///|
test "streaming mask handles overlaps Unicode multiple values and multiline credentials" {
  assert_eq(mask_log("prefix abc", ["abc", "abcdef"]), ("prefix ", "abc"))
  assert_eq(
    mask_log("abcdef and abc!", ["abc", "abcdef"]),
    ("*** and ***!", ""),
  )
  assert_eq(
    mask_log("before 密钥 after", ["密钥"]),
    ("before *** after", ""),
  )
  let masks = secret_masks("one-secret\ntwo-secret\n")
  assert_eq(mask_log("one-secret and two-secret!", masks), ("*** and ***!", ""))
  assert_eq(
    mask_log(
      "nested-private-value!",
      secret_masks("{\"registry\": [{\"token\":\"nested-private-value\"}]}"),
    ),
    ("***!", ""),
  )
}

///|
async test "rotated values apply to later steps and reruns without changing the source snapshot" {
  with_secret_fixture(
    (pool, root, coordinator, run) => {
      let actor = @identity.active_user_by_name(pool, "alice")
      let assignment = coordinator
        .claim(provider_secret, claim_request())
        .unwrap()
      let id = @protocol.parse_decimal(assignment.attempt_id).unwrap()
      let request : @protocol.SecretRequest = {
        version: 1,
        execution_id: "c".repeat(32),
        step_id: "check",
      }
      ignore(
        coordinator.start(
          id,
          attempt_secret,
          1,
          execution_id=request.execution_id,
        ),
      )
      ignore(
        coordinator.update_step(id, attempt_secret, {
          version: 1,
          step_id: "check",
          state: "running",
          exit_code: 0,
        }),
      )
      assert_eq(
        coordinator.step_secrets(id, attempt_secret, request).env.get(
          "CREDENTIALS",
        ),
        Some(credentials_fixture),
      )
      let current = list_secrets(pool, actor, protocol_repo)[0]
      save_secret(
        pool,
        root,
        actor,
        protocol_repo,
        current.name,
        Some("next-step-value"),
        current.branch,
        current.workflow_path,
        current.version,
      )
      ignore(
        coordinator.update_step(id, attempt_secret, {
          version: 1,
          step_id: "check",
          state: "success",
          exit_code: 0,
        }),
      )
      ignore(
        coordinator.update_step(id, attempt_secret, {
          version: 1,
          step_id: "later",
          state: "running",
          exit_code: 0,
        }),
      )
      assert_eq(
        coordinator.step_secrets(id, attempt_secret, {
          ..request,
          step_id: "later",
        }).env.get("CREDENTIALS"),
        Some("next-step-value"),
      )
      ignore(
        coordinator.update_step(id, attempt_secret, {
          version: 1,
          step_id: "later",
          state: "success",
          exit_code: 0,
        }),
      )
      ignore(coordinator.complete(id, attempt_secret, completion()))
      let rerun = rerun_run(pool, root, actor, protocol_repo, run.number)
      assert_eq(rerun.commit_sha, run.commit_sha)
      assert_eq(rerun.workflow_source, run.workflow_source)
      let token = "d".repeat(64)
      let assigned = coordinator
        .claim(provider_secret, claim_request(id="2", secret=token))
        .unwrap()
      let next_id = @protocol.parse_decimal(assigned.attempt_id).unwrap()
      ignore(
        coordinator.start(next_id, token, 1, execution_id=request.execution_id),
      )
      ignore(
        coordinator.update_step(next_id, token, {
          version: 1,
          step_id: "check",
          state: "running",
          exit_code: 0,
        }),
      )
      assert_eq(
        coordinator.step_secrets(next_id, token, request).env.get("CREDENTIALS"),
        Some("next-step-value"),
      )
    },
    two_steps=true,
  )
}

///|
async test "repository members cannot manage secrets and revoked provider grants prevent delivery" {
  with_secret_fixture((pool, _, coordinator, _) => {
    let bob = @identity.active_user_by_name(pool, "bob")
    pool.with_client(client => {
      ignore(
        client.execute(
          "INSERT INTO team_member(team_id, user_id, role) SELECT team_id, ?, 'member' FROM repository WHERE id = 1",
          params=[bob.id],
        ),
      )
    })
    try ignore(list_secrets(pool, bob, protocol_repo)) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("ordinary repository member managed secrets")
    }
    let assigned = coordinator.claim(provider_secret, claim_request()).unwrap()
    let id = @protocol.parse_decimal(assigned.attempt_id).unwrap()
    let request : @protocol.SecretRequest = {
      version: 1,
      execution_id: "c".repeat(32),
      step_id: "check",
    }
    ignore(
      coordinator.start(
        id,
        attempt_secret,
        1,
        execution_id=request.execution_id,
      ),
    )
    ignore(
      coordinator.update_step(id, attempt_secret, {
        version: 1,
        step_id: "check",
        state: "running",
        exit_code: 0,
      }),
    )
    let admin = @identity.active_user_by_name(pool, "admin")
    coordinator.set_provider_scope(
      admin,
      coordinator.list_providers(admin)[0].id,
      SelectedRepositories,
      [],
    )
    try ignore(coordinator.step_secrets(id, attempt_secret, request)) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("revoked provider grant exposed a secret")
    }
  })
}
