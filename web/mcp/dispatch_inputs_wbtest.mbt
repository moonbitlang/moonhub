///|
test "MCP dispatch schema allows only a bounded scalar input object" {
  let tool = tool_catalog()
    .iter()
    .find_first(tool => tool.name == "moonhub_create_run")
    .unwrap()
  assert_true(
    tool.definition()
    is {
      "inputSchema": {
        "properties": {
          "inputs": {
            "type": String("object"),
            "maxProperties": Number(25, ..),
            ..
          },
          ..
        },
        ..
      },
      ..
    },
  )
  let args : Map[String, Json] = {
    "repository": "alice/demo",
    "branch": "master",
    "workflow": ".github/workflows/build.yml",
    "inputs": { "version": "1.2.3", "release": false, "count": 2 },
  }
  tool.validate(args)
  for
    invalid in [
      Json("bad"),
      Json::null(),
      Json::object({ "x": Json::object(Map([])) }),
      Json::object({ "x": Json::array([]) }),
      Json({ "x": Json::null() }),
    ] {
    args["inputs"] = invalid
    try tool.validate(args) catch {
      ProtocolError(400, -32602, _, _) => ()
      err => raise err
    } noraise {
      _ => fail("accepted invalid dispatch inputs")
    }
  }
}

///|
async test "MCP create run preserves typed dispatch input values" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let execute = @identity.create_access_token(
      pool, actor, "dispatch", "execute", 1,
    )
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let workflow = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on:\n  workflow_dispatch:\n    inputs:\n      version: {required: true}\n      release: {type: boolean, default: false}\n      count: {type: number, default: 1}",
    )
    ignore(@test_support.workflow_commit(repo.git_dir(root), workflow))
    let (_, missing) = mcp_tool(port, execute, "moonhub_create_run", {
      "repository": "alice/demo",
      "branch": "pipeline",
      "workflow": ".github/workflows/build.yml",
    })
    assert_true(missing is { "result": { "isError": True, .. }, .. })
    let (_, data) = mcp_tool(port, execute, "moonhub_create_run", {
      "repository": "alice/demo",
      "branch": "pipeline",
      "workflow": ".github/workflows/build.yml",
      "inputs": { "version": "1.2.3", "release": true, "count": 2.5 },
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": {
            "number": String("1"),
            "context": {
              "inputs": {
                "version": String("1.2.3"),
                "release": True,
                "count": Number(2.5, ..),
                ..
              },
              ..
            },
            ..
          },
          ..
        },
        ..
      },
    )
  })
}

///|
async test "MCP transports the maximum UTF8 dispatch payload with bounded tool-specific overhead" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let token = @identity.create_access_token(
      pool, actor, "dispatch", "execute", 1,
    )
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let workflow = @test_support.single_job_workflow.replace_all(
      old="on: workflow_dispatch",
      new="on:\n  workflow_dispatch:\n    inputs:\n      payload: {required: true}",
    )
    ignore(@test_support.workflow_commit(repo.git_dir(root), workflow))
    let overhead = @utf8.encode(Json({ "payload": "" }).stringify()).length()
    let remaining = 65535 - overhead
    let value = "文".repeat(remaining / 3) + "a".repeat(remaining % 3)
    let inputs : Json = { "payload": value }
    assert_eq(@utf8.encode(inputs.stringify()).length(), 65535)
    let request = mcp_request("tools/call", {
      "name": "moonhub_create_run",
      "arguments": {
        "repository": "alice/demo",
        "branch": "pipeline",
        "workflow": ".github/workflows/build.yml",
        "inputs": inputs,
      },
    })
    assert_true(@utf8.encode(request.stringify()).length() > 65536)
    let (created, run) = mcp_http(port, token, request)
    assert_eq(created, 200)
    assert_true(
      run
      is {
        "result": {
          "isError": False,
          "structuredContent": {
            "context": { "inputs": Object(actual), .. },
            ..
          },
          ..
        },
        ..
      } &&
      actual.get("payload") == Some(Json(value)),
    )
    let (invalid, error) = mcp_tool(port, token, "moonhub_create_run", {
      "repository": "alice/demo",
      "branch": "pipeline",
      "workflow": ".github/workflows/build.yml",
      "inputs": { "payload": value + "x" },
    })
    assert_eq(invalid, 200)
    assert_true(error is { "result": { "isError": True, .. }, .. })
    assert_true(error.stringify().contains("65535"))
    let (oversized, error) = mcp_tool(port, token, "moonhub_create_run", {
      "repository": "alice/demo",
      "branch": "x".repeat(73728),
      "workflow": "build.yml",
    })
    assert_eq(oversized, 400)
    assert_true(
      error
      is { "error": { "message": String("request body is too large"), .. }, .. },
    )
    let request = mcp_request("tools/call", {
      "name": "moonhub_get_user",
      "arguments": {},
    }).stringify()
    let (unchanged, error) = mcp_http_raw(
      port,
      token,
      request + " ".repeat(65537 - @utf8.encode(request).length()),
      "tools/call",
      tool_name=Some("moonhub_get_user"),
    )
    assert_eq(unchanged, 400)
    assert_true(
      error
      is { "error": { "message": String("request body is too large"), .. }, .. },
    )
    assert_eq(@pipeline.list_runs(pool, actor, repo).length(), 1)
  })
}
