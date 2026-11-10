///|
async fn oidc_get(
  port : Int32,
  path : String,
  token~ : String = "",
) -> (Int32, Json) {
  let client = @http.Client("http://127.0.0.1:" + port.to_string())
  defer client.close()
  let response = client.get(path, extra_headers={
    "Authorization": "Bearer " + token,
    "X-Forwarded-Host": "attacker.example",
  })
  assert_eq(response.headers.get("cache-control"), Some("no-store"))
  (response.code, @json.parse(client.read_all().text()))
}

///|
async test "OIDC HTTP discovery keys and scoped token exchange enforce execution and audience" {
  let workflow = "permissions: {contents: read, id-token: write}\n" +
    artifact_http_workflow
  with_artifact_http(
    (port, c, _, _, a, lease) => {
      let origin = "http://127.0.0.1:" + port.to_string()
      let (status, discovery) = oidc_get(
        port, "/.well-known/openid-configuration",
      )
      assert_eq(status, 200)
      assert_true(
        discovery is { "issuer": String(value), .. } && value == origin,
      )
      let (status, keys) = oidc_get(port, "/-/oidc/jwks")
      assert_eq(status, 200)
      assert_true(
        keys is { "keys": [Object(key)], .. } &&
        key.get("kty") == Some(Json::string("RSA")) &&
        !key.contains("d"),
      )
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      let path = "/attempts/" + a.attempt_id + "/oidc-runtime"
      let request : @protocol.OidcRuntimeRequest = {
        version: 1,
        execution_id: "e".repeat(32),
      }
      assert_eq(
        post_json(port, path, ToJson::to_json(request).stringify(), token=lease).0,
        401,
      )
      ignore(c.start(id, lease, 1, execution_id=request.execution_id))
      let (status, json) = post_json(
        port,
        path,
        ToJson::to_json(request).stringify(),
        token=lease,
      )
      assert_eq(status, 200)
      let grant : @protocol.OidcRuntime = @json.from_json(json)
      let endpoint = "/-/oidc/token?attempt_id=" + a.attempt_id
      assert_eq(oidc_get(port, endpoint, token=lease).0, 401)
      assert_eq(oidc_get(port, endpoint, token="a".repeat(64)).0, 401)
      assert_eq(
        oidc_get(port, endpoint + "&audience=untrusted", token=grant.token).0,
        400,
      )
      assert_eq(
        oidc_get(
          port,
          endpoint + "&attempt_id=" + a.attempt_id,
          token=grant.token,
        ).0,
        400,
      )
      assert_eq(
        oidc_get(
          port,
          endpoint + "&audience=sts.amazonaws.com&audience=other",
          token=grant.token,
        ).0,
        400,
      )
      assert_eq(
        oidc_get(port, endpoint + "&sub=forged", token=grant.token).0,
        400,
      )
      let (status, response) = oidc_get(
        port,
        endpoint + "&audience=sts.amazonaws.com",
        token=grant.token,
      )
      assert_eq(status, 200)
      assert_true(
        response is { "value": String(jwt), .. } && jwt.split(".").count() == 3,
      )
      assert_eq(c.oidc_jwks(), keys)
    },
    workflow~,
    oidc=true,
  )
}

///|
async test "real runner carries OIDC through shell JavaScript pre main post and denies the next job" {
  let (node_code, node_output) = @process.collect_output_merged("node", [
    "-p", "process.execPath",
  ])
  assert_eq(node_code, 0)
  let test_node = node_output.text().trim().to_owned()
  let workflow =
    #|name: OIDC runner acceptance
    #|on: workflow_dispatch
    #|permissions: {id-token: write}
    #|jobs:
    #|  prove:
    #|    runs-on: self-hosted
    #|    outputs:
    #|      jwt: ${{ steps.proof.outputs.jwt }}
    #|      repository: ${{ steps.proof.outputs.repository }}
    #|    steps:
    #|      - name: Prepare action and request from shell
    #|        env:
    #|          TEST_NODE: ${{ vars.TEST_NODE }}
    #|        run: |
    #|          test -n "$ACTIONS_ID_TOKEN_REQUEST_URL"
    #|          test -n "$ACTIONS_ID_TOKEN_REQUEST_TOKEN"
    #|          mkdir proof
    #|          printf '%s\n' 'runs: {using: node24, pre: proof.cjs, main: proof.cjs, post: proof.cjs}' > proof/action.yml
    #|          cat > proof/proof.cjs <<'JS'
    #|          (async()=>{const fs=require('fs'), c=require('crypto');const u=process.env.ACTIONS_ID_TOKEN_REQUEST_URL+'&audience=sts.amazonaws.com';const response=await fetch(u,{headers:{Authorization:'Bearer '+process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN}});if(!response.ok)throw Error('request failed '+response.status);const {value}=await response.json();const [h,p,s]=value.split('.');const claims=JSON.parse(Buffer.from(p,'base64url'));const header=JSON.parse(Buffer.from(h,'base64url'));const {keys}=await(await fetch(claims.iss+'/-/oidc/jwks')).json();const key=keys.find(k=>k.kid===header.kid);if(!c.verify('RSA-SHA256',Buffer.from(h+'.'+p),c.createPublicKey({key,format:'jwk'}),Buffer.from(s,'base64url'))||claims.repository!=='alice/demo'||!claims.sub.endsWith(':ref:refs/heads/pipeline'))throw Error('identity mismatch');console.log(value);console.log(process.env.ACTIONS_ID_TOKEN_REQUEST_TOKEN);fs.appendFileSync(process.env.GITHUB_OUTPUT,'repository='+claims.repository+'\njwt='+value+'\n');fs.appendFileSync(process.env.GITHUB_WORKSPACE+'/proof-count','1');})().catch(e=>{console.error(e);process.exitCode=1});
    #|          JS
    #|          "$TEST_NODE" proof/proof.cjs
    #|      - id: proof
    #|        uses: ./proof
    #|  unprivileged:
    #|    needs: prove
    #|    permissions: {}
    #|    runs-on: self-hosted
    #|    steps:
    #|      - run: |
    #|          test -z "${ACTIONS_ID_TOKEN_REQUEST_URL:-}"
    #|          test -z "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}"
    #|          test "$REPOSITORY" = alice/demo
    #|        env:
    #|          REPOSITORY: ${{ needs.prove.outputs.repository }}
  with_artifact_http(
    (port, c, pool, _, first, lease) => {
      @test_support.with_runner_workspace((root, launcher, _) => {
        let (code, node) = @process.collect_output_merged("node", [
          "-p", "process.execPath",
        ])
        assert_eq(code, 0)
        let mut assignment = first
        let mut token = lease
        for index = 0; index < 2; index = index + 1 {
          let workspace = root + "/job-" + index.to_string()
          @fs.mkdir(workspace)
          let report = @runner.run(
            assignment,
            token,
            {
              server: "http://127.0.0.1:" + port.to_string(),
              workspace,
              launcher,
              allow_http: true,
              unsafe_local: true,
              heartbeat_ms: 50,
            },
            action_node=node.text().trim().to_owned(),
            action_runtime=@fs.realpath("runner/actions/runtime.mjs"),
          )
          let text = pool.with_client(client => {
            client
            .query_all(
              "SELECT content FROM pipeline_log_chunk WHERE attempt_id=?",
              params=[@protocol.parse_decimal(assignment.attempt_id).unwrap()],
            )
            .map(row => (row.get_name("content") : String))
            .join("")
          })
          assert_eq(report.conclusion, "success", msg=text)
          assert_true(report.reported)
          if index == 0 {
            assert_eq(
              @fs.read_file(workspace + "/repository/proof-count").text(),
              "1111",
            )
            assert_true(!text.contains("eyJ"))
            let outputs = pool.with_client(client => {
              client
              .query_all(
                "SELECT outputs_json FROM pipeline_job_output WHERE attempt_id=?",
                params=[@protocol.parse_decimal(assignment.attempt_id).unwrap()],
              )
              .map(row => @json.parse((row.get_name("outputs_json") : String)))
            })
            assert_true(
              outputs is [Object(fields)] &&
              !fields.contains("jwt") &&
              fields.get("repository") == Some(Json::string("alice/demo")),
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
            assert_false(assignment.job.id_token_write)
          }
        }
      })
    },
    workflow~,
    oidc=true,
    variables={ "TEST_NODE": test_node },
  )
}

///|
async test "OIDC upstream AWS Action exchanges a verifiable identity through real HTTP endpoints" {
  if @env.get_env_var("MOONHUB_OIDC_UPSTREAM") != Some("1") {
    return
  }
  with_artifact_http(
    (port, c, pool, root, a, lease) => {
      let id = @protocol.parse_decimal(a.attempt_id).unwrap()
      ignore(c.start(id, lease, 1, execution_id="e".repeat(32)))
      let grant = c.oidc_runtime(id, lease, {
        version: 1,
        execution_id: "e".repeat(32),
      })
      let repository_id = pool.with_client(client => {
        (
          client
          .query_one("SELECT repository_id FROM pipeline_run WHERE id=?", params=[
            @protocol.parse_decimal(a.run_id).unwrap(),
          ])
          .get_name("repository_id") : Int64)
      })
      let config : Json = {
        "root": root,
        "token": grant.token,
        "request_url": grant.request_url,
        "issuer": "http://127.0.0.1:" + port.to_string(),
        "sha": a.commit_sha,
        "run_id": a.run_id,
        "repository_id": repository_id.to_string(),
      }
      let path = root + "/oidc-upstream.json"
      @fs.write_file(path, config.stringify(), permission=0o600)
      let (code, output) = @process.collect_output_merged("node", [
        "scripts/oidc-upstream-smoke.mjs", path,
      ])
      assert_eq(code, 0, msg=output.text())
      assert_true(output.text().contains("OIDC upstream acceptance passed"))
    },
    workflow="permissions: {id-token: write}\n" + artifact_http_workflow,
    oidc=true,
  )
}
