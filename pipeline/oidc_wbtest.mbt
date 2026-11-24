///|
async fn with_oidc_fixture(
  f : async (
    PipelineFixture,
    @database.Database,
    String,
    @runtime.Run,
    @runtime.Provider,
    Ref[Int64],
  ) -> Unit,
  permission~ : Bool = true,
) -> Unit {
  with_protocol_fixture(
    (_, pool, root, run, provider, clock) => {
      let path = root + "/oidc.json"
      @test_support.create_oidc_config(path, "https://issuer.example")
      let issuer = @oidc.OidcIssuer::load(path)
      let c = test_services(pool, oidc=issuer, clock=() => clock.val)
      f(c, pool, root, run, provider, clock)
    },
    workflow=if permission {
      "permissions: {contents: read, id-token: write}\n" +
      @test_support.single_job_workflow
    } else {
      @test_support.single_job_workflow
    },
  )
}

///|
async test "OIDC signs verifiable JWTs from immutable snapshots with separate masked credentials" {
  with_oidc_fixture((c, pool, _, run, _, clock) => {
    let a = c.runtime.claim(provider_secret, claim_request()).unwrap()
    assert_eq(a.version, @protocol.release_assignment_version)
    assert_true(a.job.id_token_write)
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.runtime.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
    let grant = c.oidc.oidc_runtime(id, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    assert_true(grant.token != attempt_secret && grant.token != provider_secret)
    assert_eq(
      grant.request_url,
      "https://issuer.example/-/oidc/token?attempt_id=" + a.attempt_id,
    )
    let response = c.oidc.oidc_token(id, grant.token, "sts.amazonaws.com")
    let jwt = artifact_test_string(response, "value")
    let (code, output, _) = @process.collect_output(
      "node",
      [
        "-e",
        "const c=require('node:crypto');const [h,p,s]=process.argv[1].split('.');const header=JSON.parse(Buffer.from(h,'base64url'));const keys=JSON.parse(process.argv[2]).keys;const key=keys.find(k=>k.kid===header.kid);if(header.alg!=='RS256'||!c.verify('RSA-SHA256',Buffer.from(h+'.'+p),c.createPublicKey({key,format:'jwk'}),Buffer.from(s,'base64url')))process.exit(2);process.stdout.write(Buffer.from(p,'base64url'));",
        jwt,
        c.oidc.oidc_jwks().stringify(),
      ],
      inherit_env=false,
    )
    assert_eq(code, 0)
    let claims = @json.parse(output.text())
    assert_eq(artifact_test_string(claims, "iss"), "https://issuer.example")
    assert_eq(artifact_test_string(claims, "aud"), "sts.amazonaws.com")
    assert_eq(
      artifact_test_string(claims, "sub"),
      "repo_id:" + run.repository_id.to_string() + ":ref:refs/heads/pipeline",
    )
    assert_eq(artifact_test_string(claims, "sha"), run.commit_sha)
    assert_eq(artifact_test_string(claims, "repository"), "alice/demo")
    assert_true(
      claims is { "iat": Number(iat, ..), "exp": Number(exp, ..), .. } &&
      iat == (clock.val / 1000L).to_double() &&
      exp == iat + Int32::min(300, a.job.timeout_minutes * 60).to_double(),
    )
    assert_true(!ToJson::to_json(a).stringify().contains(grant.token))
    assert_true(!c.oidc.oidc_jwks().stringify().contains("private"))
    ignore(
      c.runtime.append_log(
        id,
        attempt_secret,
        log_request(1L, grant.token + " " + jwt + "\n"),
      ),
    )
    let reader = @identity.active_user_by_name(pool, "alice")
    let text = c.runtime.read_log_page(reader, protocol_repo, run.number, id).chunks
      .map(chunk => chunk.text)
      .join("")
    assert_true(!text.contains(jwt) && !text.contains(grant.token))
    for wrong in [attempt_secret, provider_secret, "c".repeat(64)] {
      try ignore(c.oidc.oidc_token(id, wrong, "sts.amazonaws.com")) catch {
        @domain.Unauthorized(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted another credential type")
      }
    }
    try
      ignore(c.oidc.oidc_token(id + 1L, grant.token, "sts.amazonaws.com"))
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted another attempt")
    }
    try ignore(c.oidc.oidc_token(id, grant.token, "untrusted")) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted unconfigured audience")
    }
    let restarted = test_services(pool, oidc=c.issuer.unwrap(), clock=() => {
      clock.val
    })
    ignore(restarted.oidc.oidc_token(id, grant.token, ""))
    for step in a.job.steps {
      for state in ["running", "success"] {
        ignore(
          c.runtime.update_step(id, attempt_secret, {
            version: 1,
            step_id: step.id,
            state,
            exit_code: 0,
          }),
        )
      }
    }
    ignore(c.runtime.complete(id, attempt_secret, completion(last=1L)))
    try ignore(c.oidc.oidc_token(id, grant.token, "")) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("issued after completion")
    }
  })
}

///|
async test "OIDC checks permission execution binding cancellation expiration and provider revocation" {
  with_oidc_fixture((c, pool, _, _, provider, clock) => {
    let a = c.runtime.claim(provider_secret, claim_request()).unwrap()
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    try
      ignore(
        c.oidc.oidc_runtime(id, attempt_secret, {
          version: 1,
          execution_id: "e".repeat(32),
        }),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("issued before start")
    }
    ignore(c.runtime.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
    try
      ignore(
        c.oidc.oidc_runtime(id, attempt_secret, {
          version: 1,
          execution_id: "f".repeat(32),
        }),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted wrong execution")
    }
    let grant = c.oidc.oidc_runtime(id, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_job_attempt SET cancel_at_ms=? WHERE id=?",
          params=[clock.val, id],
        ),
      )
    })
    try ignore(c.oidc.oidc_token(id, grant.token, "")) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("issued during cancellation")
    }
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_job_attempt SET cancel_at_ms=NULL WHERE id=?",
          params=[id],
        ),
      )
    })
    let saved = clock.val
    clock.val += 60001L
    try ignore(c.oidc.oidc_token(id, grant.token, "")) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("issued on expired lease")
    }
    clock.val = saved
    pool.with_client(client => {
      ignore(
        client.execute("UPDATE pipeline_provider SET revoked=1 WHERE id=?", params=[
          provider.id,
        ]),
      )
    })
    try ignore(c.oidc.oidc_token(id, grant.token, "")) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("issued after provider revocation")
    }
  })
  with_oidc_fixture(
    (c, _, _, _, _, _) => {
      let a = c.runtime.claim(provider_secret, claim_request()).unwrap()
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      ignore(
        c.runtime.start(id, attempt_secret, 1, execution_id="e".repeat(32)),
      )
      try
        ignore(
          c.oidc.oidc_runtime(id, attempt_secret, {
            version: 1,
            execution_id: "e".repeat(32),
          }),
        )
      catch {
        @domain.Unauthorized(_) => ()
        err => raise err
      } noraise {
        _ => fail("issued without permission")
      }
    },
    permission=false,
  )
}

///|
async test "OIDC request budgets persist across expired grants and actor access is rechecked" {
  with_oidc_fixture((c, pool, _, _, _, clock) => {
    let a = c.runtime.claim(provider_secret, claim_request()).unwrap()
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.runtime.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
    let grant = c.oidc.oidc_runtime(id, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_oidc_runtime SET requests=256,expires_ms=? WHERE attempt_id=?",
          params=[clock.val, id],
        ),
      )
    })
    let fresh = c.oidc.oidc_runtime(id, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    try ignore(c.oidc.oidc_token(id, grant.token, "")) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted expired grant")
    }
    try ignore(c.oidc.oidc_token(id, fresh.token, "")) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("reset request budget with a fresh grant")
    }
    pool.with_client(client => {
      ignore(
        client.execute(
          "UPDATE pipeline_oidc_runtime SET requests=0 WHERE attempt_id=?",
          params=[id],
        ),
      )
      ignore(
        client.execute(
          "UPDATE \"user\" SET status='disabled' WHERE name_key='alice'",
        ),
      )
    })
    try ignore(c.oidc.oidc_token(id, fresh.token, "")) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("issued after actor disablement")
    }
  })
}

///|
async test "OIDC pull request identity never receives its target branch subject" {
  with_merge_check_fixture(
    (pool, root, _, _, mr) => {
      poll_merge_checks(pool, root)
      ignore(merge_check_provider(pool))
      let path = root + "/oidc.json"
      @test_support.create_oidc_config(path, "https://issuer.example")
      let issuer = @oidc.OidcIssuer::load(path)
      let c = test_services(pool, oidc=issuer)
      let (a, token) = claim_dag_attempt(c, provider_secret)
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      ignore(c.runtime.start(id, token, 1, execution_id="e".repeat(32)))
      let grant = c.oidc.oidc_runtime(id, token, {
        version: 1,
        execution_id: "e".repeat(32),
      })
      let jwt = c.oidc.oidc_token(id, grant.token, "")
      guard jwt is { "value": String(value), .. } else { fail("missing JWT") }
      let payload = value.split(".").collect()[1].to_owned()
      let payload = payload
        .replace_all(old="-", new="+")
        .replace_all(old="_", new="/")
      let payload = payload + "=".repeat((4 - payload.length() % 4) % 4)
      let claims = @json.parse(@utf8.decode(@base64.decode(payload)))
      assert_eq(
        artifact_test_string(claims, "ref"),
        "refs/pull/" + mr.number.to_string() + "/merge",
      )
      assert_eq(artifact_test_string(claims, "event_name"), "pull_request")
      assert_true(
        artifact_test_string(claims, "sub").has_suffix(":pull_request"),
      )
      assert_true(
        !artifact_test_string(claims, "sub").contains("refs/heads/master"),
      )
    },
    workflow="permissions: {contents: read, id-token: write}\n" +
      pull_request_workflow,
    required=false,
  )
}

///|
async test "OIDC legacy definition six keeps assignment nine and cannot gain identity access" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let scope = @repository.repository_scope(pool, actor, protocol_repo)
    let source = "permissions: {contents: read, id-token: write}\n" +
      @test_support.single_job_workflow
    let sha = @test_support.workflow_commit(protocol_repo.git_dir(root), source)
    let pin = "refs/moonhub/pipelines/legacy-oidc"
    ignore(
      @gitops.merge_git(protocol_repo.git_dir(root), ["update-ref", pin, sha]),
    )
    let run = pool.with_client(client => {
      client.with_transaction(tx => {
        insert_run_snapshot(
          tx,
          scope.id,
          actor.id,
          ".github/workflows/build.yml",
          "Legacy OIDC",
          "pipeline",
          sha,
          pin,
          source,
          @workflow.parse(source),
          definition_version=6,
          context=Some({
            repository: "alice/demo",
            sha,
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
    ignore(merge_check_provider(pool))
    let path = root + "/oidc.json"
    @test_support.create_oidc_config(path, "https://issuer.example")
    let issuer = @oidc.OidcIssuer::load(path)
    let c = test_services(pool, oidc=issuer)
    let (a, token) = claim_dag_attempt(c, provider_secret)
    assert_eq(a.run_id, run.id.to_string())
    assert_eq(a.version, @protocol.variable_assignment_version)
    assert_false(a.job.id_token_write)
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.runtime.start(id, token, 1, execution_id="e".repeat(32)))
    try
      ignore(
        c.oidc.oidc_runtime(id, token, {
          version: 1,
          execution_id: "e".repeat(32),
        }),
      )
    catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("old definition gained OIDC access")
    }
  })
}

///|
async test "OIDC definition seven ordinary jobs retain the complete v9 execution contract" {
  with_oidc_fixture(
    (c, _, _, run, _, _) => {
      assert_eq(run.definition_version, @workflow.format_version)
      let a = c.runtime.claim(provider_secret, claim_request()).unwrap()
      assert_eq(a.version, @protocol.variable_assignment_version)
      assert_false(a.job.id_token_write)
      assert_eq(a.job.contents_read, run.definition.jobs[0].contents_read)
      assert_eq(a.job.context.get("actor"), Some("alice"))
    },
    permission=false,
  )
}
