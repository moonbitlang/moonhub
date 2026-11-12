///|
async fn with_oidc_fixture(
  f : async (Coordinator, @database.Database, String, Run, Provider, Ref[Int64]) -> Unit,
  permission~ : Bool = true,
) -> Unit {
  with_protocol_fixture(
    (_, pool, root, run, provider, clock) => {
      let path = root + "/oidc.json"
      @test_support.create_oidc_config(path, "https://issuer.example")
      let issuer = OidcIssuer::load(path)
      let c = Coordinator::new(pool, oidc=issuer, clock=() => clock.val)
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
    let a = c.claim(provider_secret, claim_request()).unwrap()
    assert_eq(a.version, @protocol.oidc_assignment_version)
    assert_true(a.job.id_token_write)
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
    let grant = c.oidc_runtime(id, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    assert_true(grant.token != attempt_secret && grant.token != provider_secret)
    assert_eq(
      grant.request_url,
      "https://issuer.example/-/oidc/token?attempt_id=" + a.attempt_id,
    )
    let response = c.oidc_token(id, grant.token, "sts.amazonaws.com")
    let jwt = artifact_test_string(response, "value")
    let (code, output, _) = @process.collect_output(
      "node",
      [
        "-e",
        "const c=require('node:crypto');const [h,p,s]=process.argv[1].split('.');const header=JSON.parse(Buffer.from(h,'base64url'));const keys=JSON.parse(process.argv[2]).keys;const key=keys.find(k=>k.kid===header.kid);if(header.alg!=='RS256'||!c.verify('RSA-SHA256',Buffer.from(h+'.'+p),c.createPublicKey({key,format:'jwk'}),Buffer.from(s,'base64url')))process.exit(2);process.stdout.write(Buffer.from(p,'base64url'));",
        jwt,
        c.oidc_jwks().stringify(),
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
    assert_true(!c.oidc_jwks().stringify().contains("private"))
    ignore(
      c.append_log(
        id,
        attempt_secret,
        log_request(1L, grant.token + " " + jwt + "\n"),
      ),
    )
    let reader = @identity.active_user_by_name(pool, "alice")
    let text = c.read_log_page(reader, protocol_repo, run.number, id).chunks
      .map(chunk => chunk.text)
      .join("")
    assert_true(!text.contains(jwt) && !text.contains(grant.token))
    for wrong in [attempt_secret, provider_secret, "c".repeat(64)] {
      try ignore(c.oidc_token(id, wrong, "sts.amazonaws.com")) catch {
        @domain.Unauthorized(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted another credential type")
      }
    }
    try ignore(c.oidc_token(id + 1L, grant.token, "sts.amazonaws.com")) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted another attempt")
    }
    try ignore(c.oidc_token(id, grant.token, "untrusted")) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted unconfigured audience")
    }
    let restarted = Coordinator::new(pool, oidc=c.oidc.unwrap(), clock=() => {
      clock.val
    })
    ignore(restarted.oidc_token(id, grant.token, ""))
    for step in a.job.steps {
      for state in ["running", "success"] {
        ignore(
          c.update_step(id, attempt_secret, {
            version: 1,
            step_id: step.id,
            state,
            exit_code: 0,
          }),
        )
      }
    }
    ignore(c.complete(id, attempt_secret, completion(last=1L)))
    try ignore(c.oidc_token(id, grant.token, "")) catch {
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
    let a = c.claim(provider_secret, claim_request()).unwrap()
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    try
      ignore(
        c.oidc_runtime(id, attempt_secret, {
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
    ignore(c.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
    try
      ignore(
        c.oidc_runtime(id, attempt_secret, {
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
    let grant = c.oidc_runtime(id, attempt_secret, {
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
    try ignore(c.oidc_token(id, grant.token, "")) catch {
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
    try ignore(c.oidc_token(id, grant.token, "")) catch {
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
    try ignore(c.oidc_token(id, grant.token, "")) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("issued after provider revocation")
    }
  })
  with_oidc_fixture(
    (c, _, _, _, _, _) => {
      let a = c.claim(provider_secret, claim_request()).unwrap()
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      ignore(c.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
      try
        ignore(
          c.oidc_runtime(id, attempt_secret, {
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
async test "OIDC configuration rejects non-RSA weak keys insecure issuers and private previous keys" {
  @test_support.with_repository_test_data((_, root) => {
    let path = root + "/oidc.json"
    @test_support.create_oidc_config(path, "http://issuer.example")
    try ignore(OidcIssuer::load(path)) catch {
      @domain.BadRequest(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted HTTP issuer")
    }
    @test_support.create_oidc_config(path, "https://issuer.example")
    let issuer = OidcIssuer::load(path)
    assert_true(
      issuer.discovery()
      is {
        "issuer": String("https://issuer.example"),
        "jwks_uri": String("https://issuer.example/-/oidc/jwks"),
        ..
      },
    )
    for kind in ["rsa", "ec"] {
      let code = @process.run(
        "node",
        [
          "-e", "const c=require('node:crypto'),fs=require('node:fs');const type=process.argv[2];const {privateKey}=c.generateKeyPairSync(type,type==='rsa'?{modulusLength:1024}:{namedCurve:'prime256v1'});fs.writeFileSync(process.argv[1],JSON.stringify({issuer:'https://issuer.example',private_key:privateKey.export({type:'pkcs8',format:'pem'})}),{mode:0o600});",
          path, kind,
        ],
        inherit_env=false,
      )
      assert_eq(code, 0)
      try ignore(OidcIssuer::load(path)) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted weak or non-RSA key")
      }
    }
    @test_support.create_oidc_config(path, "https://issuer.example")
    let original = @fs.read_file(path).text()
    for field in ["issuer", "private_key", "audiences", "previous_keys"] {
      let json = @json.parse(original)
      guard json is Object(fields) else { fail("invalid config") }
      fields[field] = match field {
        "issuer" => "https://issuer.example/"
        "private_key" => "broken private key"
        "audiences" => ["", "sts.amazonaws.com"]
        _ => [{ "kty": "RSA", "n": "abc", "e": "AQAB", "d": "private" }]
      }
      @fs.write_file(path, json.stringify())
      try ignore(OidcIssuer::load(path)) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("accepted invalid " + field)
      }
    }
  })
}

///|
async test "OIDC key rotation publishes old public keys while signing with the new key" {
  @test_support.with_repository_test_data((_, root) => {
    let old_path = root + "/old-key.json"
    let new_path = root + "/new-key.json"
    @test_support.create_oidc_config(old_path, "https://issuer.example")
    @test_support.create_oidc_config(new_path, "https://issuer.example")
    let old = OidcIssuer::load(old_path)
    let config = @json.parse(@fs.read_file(new_path).text())
    guard config is Object(fields) else { fail("invalid config") }
    fields["previous_keys"] = old.keys
    @fs.write_file(new_path, config.stringify())
    let current = OidcIssuer::load(new_path)
    assert_true(current.kid != old.kid)
    assert_true(
      current.keys is Array(keys) &&
      keys.length() == 2 &&
      keys.any(key => key is { "kid": String(kid), .. } && kid == old.kid),
    )
    let token = current.sign({ "test": true })
    let header = token.split(".").next().unwrap()
    assert_eq(
      header,
      base64url(
        @utf8.encode(
          ({ "alg": "RS256", "typ": "JWT", "kid": current.kid } : Json).stringify(),
        ),
      ),
    )
    assert_true(!current.jwks().stringify().contains("PRIVATE KEY"))
  })
}

///|
async test "OIDC fences cancellation while signing is queued" {
  with_oidc_fixture((c, pool, _, run, _, _) => {
    let a = c.claim(provider_secret, claim_request()).unwrap()
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
    let grant = c.oidc_runtime(id, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    let issuer = c.oidc.unwrap()
    for i = 0; i < 4; i = i + 1 {
      issuer.signing.acquire()
    }
    @async.with_task_group(group => {
      let waiting = group.spawn(() => {
        try ignore(c.oidc_token(id, grant.token, "")) catch {
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
      for i = 0; i < 4; i = i + 1 {
        issuer.signing.release()
      }
      waiting.wait()
    })
  })
}

///|
async test "OIDC request budgets persist across expired grants and actor access is rechecked" {
  with_oidc_fixture((c, pool, _, _, _, clock) => {
    let a = c.claim(provider_secret, claim_request()).unwrap()
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.start(id, attempt_secret, 1, execution_id="e".repeat(32)))
    let grant = c.oidc_runtime(id, attempt_secret, {
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
    let fresh = c.oidc_runtime(id, attempt_secret, {
      version: 1,
      execution_id: "e".repeat(32),
    })
    try ignore(c.oidc_token(id, grant.token, "")) catch {
      @domain.Unauthorized(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted expired grant")
    }
    try ignore(c.oidc_token(id, fresh.token, "")) catch {
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
    try ignore(c.oidc_token(id, fresh.token, "")) catch {
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
      let issuer = OidcIssuer::load(path)
      let c = Coordinator::new(pool, oidc=issuer)
      let (a, token) = claim_dag_attempt(c, provider_secret)
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      ignore(c.start(id, token, 1, execution_id="e".repeat(32)))
      let grant = c.oidc_runtime(id, token, {
        version: 1,
        execution_id: "e".repeat(32),
      })
      let claims = c.oidc_claims(id, grant.token, "", false)
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
          }),
        )
      })
    })
    ignore(merge_check_provider(pool))
    let path = root + "/oidc.json"
    @test_support.create_oidc_config(path, "https://issuer.example")
    let issuer = OidcIssuer::load(path)
    let c = Coordinator::new(pool, oidc=issuer)
    let (a, token) = claim_dag_attempt(c, provider_secret)
    assert_eq(a.run_id, run.id.to_string())
    assert_eq(a.version, @protocol.variable_assignment_version)
    assert_false(a.job.id_token_write)
    let id = @protocol.parse_decimal(a.attempt_id).unwrap()
    ignore(c.start(id, token, 1, execution_id="e".repeat(32)))
    try
      ignore(
        c.oidc_runtime(id, token, { version: 1, execution_id: "e".repeat(32), }),
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
      let a = c.claim(provider_secret, claim_request()).unwrap()
      assert_eq(a.version, @protocol.variable_assignment_version)
      assert_false(a.job.id_token_write)
      assert_eq(a.job.contents_read, run.definition.jobs[0].contents_read)
      assert_eq(a.job.context.get("actor"), Some("alice"))
    },
    permission=false,
  )
}
