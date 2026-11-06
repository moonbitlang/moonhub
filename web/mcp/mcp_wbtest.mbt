///|
fn mcp_request(
  rpc_method : String,
  params : Map[String, Json],
  id~ : Json = Json(1),
  version~ : String = "2026-07-28",
) -> Json {
  params["_meta"] = {
    "io.modelcontextprotocol/protocolVersion": version,
    "io.modelcontextprotocol/clientCapabilities": {},
    "io.modelcontextprotocol/clientInfo": {
      "name": "moonhub-tests",
      "version": "1",
    },
  }
  { "jsonrpc": "2.0", "id": id, "method": rpc_method, "params": Json(params) }
}

///|
async fn mcp_http(
  port : Int32,
  token : String,
  body : Json,
  overrides~ : Array[(String, String)] = [],
) -> (Int32, Json) {
  let headers : @http.Headers = {
    "Authorization": "Bearer " + token,
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "MCP-Protocol-Version": "2026-07-28",
  }
  if body is { "method": String(rpc_method), "params": Object(params), .. } {
    headers["Mcp-Method"] = rpc_method
    if params.get("name") is Some(String(name)) {
      headers["Mcp-Name"] = name
    }
    if params.get("_meta")
      is Some(
        { "io.modelcontextprotocol/protocolVersion": String(version), .. }
      ) {
      headers["MCP-Protocol-Version"] = version
    }
  }
  for (key, value) in overrides {
    headers[@http.CaseInsensitiveString(key)] = value
  }
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client.post("/-/mcp", body.stringify(), extra_headers=headers)
  assert_eq(response.headers.get("cache-control"), Some("no-store"))
  assert_eq(response.headers.get("mcp-session-id"), None)
  let text = client.read_all().text()
  (
    response.code,
    if text.is_empty() {
      Json::null()
    } else {
      @json.parse(text)
    },
  )
}

///|
async fn mcp_http_raw(
  port : Int32,
  token : String,
  body : String,
  rpc_method : String,
  tool_name~ : String? = None,
) -> (Int32, Json) {
  let headers : @http.Headers = {
    "Authorization": "Bearer " + token,
    "Content-Type": "application/json",
    "Accept": "application/json, text/event-stream",
    "MCP-Protocol-Version": "2026-07-28",
    "Mcp-Method": rpc_method,
  }
  if tool_name is Some(name) {
    headers["Mcp-Name"] = name
  }
  let client = @http.Client("http://127.0.0.1:\{port}")
  defer client.close()
  let response = client.post("/-/mcp", body, extra_headers=headers)
  assert_eq(response.headers.get("cache-control"), Some("no-store"))
  assert_eq(response.headers.get("mcp-session-id"), None)
  let text = client.read_all().text()
  (
    response.code,
    if text.is_empty() {
      Json::null()
    } else {
      @json.parse(text)
    },
  )
}

///|
async fn mcp_tool(
  port : Int32,
  token : String,
  name : String,
  args : Map[String, Json],
) -> (Int32, Json) {
  mcp_http(
    port,
    token,
    mcp_request("tools/call", { "name": Json(name), "arguments": Json(args) }),
  )
}

///|
async test "MCP edits target branches with version checks and preserves omitted metadata" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let write = @identity.create_access_token(
      pool, actor, "retarget", "write", 1,
    )
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let dir = repo.git_dir(root)
    ignore(
      @gitops.merge_git(dir, [
        "update-ref",
        "refs/heads/release",
        @gitops.branch_sha(dir, "master"),
      ]),
    )
    ignore(
      @test_support.merge_test_commit(
        dir,
        "feature",
        @gitops.branch_sha(dir, "master"),
        "source\n",
      ),
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, dir, actor, "Original", "Keep body", "feature", "master", false,
    )
    let (status, data) = mcp_tool(port, write, "moonhub_edit_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json(mr.number.to_string()),
      "edit_version": Json("1"),
      "target": Json("release"),
    })
    assert_eq(status, 200)
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": {
            "target": String("release"),
            "title": String("Original"),
            "description": String("Keep body"),
            "version": String("2"),
            "edit_version": String("2"),
            ..
          },
          ..
        },
        ..
      },
    )
    let (_, stale) = mcp_tool(port, write, "moonhub_edit_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json(mr.number.to_string()),
      "edit_version": Json("1"),
      "target": Json("master"),
    })
    assert_true(stale is { "result": { "isError": True, .. }, .. })
    assert_eq(
      @collaboration.require_merge_request(pool, scope, mr.number).target,
      "release",
    )
  })
}

///|
async test "MCP 2 discovery and tools work without initialization or connection state" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let read = @identity.create_access_token(pool, actor, "mcp-read", "read", 1)
    let (status, data) = mcp_tool(port, read, "moonhub_get_user", Map([]))
    assert_eq(status, 200)
    assert_true(
      data
      is {
        "id": Number(1, ..),
        "result": {
          "resultType": String("complete"),
          "structuredContent": { "username": String("alice"), .. },
          "isError": False,
          ..
        },
        ..
      },
    )
    let (status, discovery) = mcp_http(
      port,
      read,
      mcp_request("server/discover", Map([]), id=Json("discovery")),
    )
    assert_eq(status, 200)
    assert_true(
      discovery
      is {
        "id": String("discovery"),
        "result": {
          "resultType": String("complete"),
          "supportedVersions": [String("2026-07-28")],
          "capabilities": { "tools": Object(_), .. },
          "ttlMs": Number(0, ..),
          "cacheScope": String("private"),
          "_meta": {
            "io.modelcontextprotocol/serverInfo": {
              "name": String("moonhub"),
              ..
            },
            ..
          },
          ..
        },
        ..
      },
    )
    let (status, first) = mcp_http(
      port,
      read,
      mcp_request("tools/list", Map([])),
    )
    assert_eq(status, 200)
    let (_, second) = mcp_http(port, read, mcp_request("tools/list", Map([])))
    assert_eq(first, second)
    guard first is { "result": { "tools": Array(tools), .. }, .. } else {
      abort("missing tools")
    }
    assert_eq(tools.length(), 30)
    assert_true(
      tools
      .iter()
      .any(tool => {
        tool
        is {
          "name": String("moonhub_create_issue"),
          "inputSchema": { "additionalProperties": False, .. },
          "annotations": { "readOnlyHint": False, .. },
          ..
        }
      }),
    )
    let (status, _) = mcp_tool(port, read, "moonhub_list_repositories", Map([]))
    assert_eq(status, 200)
    let (status, _) = mcp_tool(port, read, "moonhub_list_inbox", Map([]))
    assert_eq(status, 200)
    let (status, encoded) = mcp_http(
      port,
      read,
      mcp_request("tools/call", { "name": Json("moonhub_get_user") }),
      overrides=[
        (
          "Mcp-Name",
          "=?base64?" + @base64.encode(@utf8.encode("moonhub_get_user")) + "?=",
        ),
        ("Mcp-Session-Id", "ignored-legacy-session"),
      ],
    )
    assert_eq(status, 200)
    assert_true(encoded is { "result": { "isError": False, .. }, .. })
  })
}

///|
async test "MCP validates metadata mirrored headers versions and request IDs independently" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let read = @identity.create_access_token(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      "mcp",
      "read",
      1,
    )
    for
      (header, value) in [
        ("Mcp-Method", "tools/call"),
        ("MCP-Protocol-Version", "2025-11-25"),
        ("Mcp-Method", ""),
        ("Mcp-Method", "tools/list, tools/list"),
      ] {
      let (status, data) = mcp_http(
        port,
        read,
        mcp_request("tools/list", Map([])),
        overrides=[(header, value)],
      )
      assert_eq(status, 400)
      assert_true(
        data
        is {
          "id": Number(1, ..),
          "error": { "code": Number(-32020, ..), .. },
          ..
        },
      )
    }
    let (status, data) = mcp_http(
      port,
      read,
      mcp_request("tools/list", Map([]), version="1900-01-01"),
    )
    assert_eq(status, 400)
    assert_true(
      data
      is {
        "error": {
          "code": Number(-32022, ..),
          "data": {
            "supported": [String("2026-07-28")],
            "requested": String("1900-01-01"),
            ..
          },
          ..
        },
        ..
      },
    )
    let (status, exact_decimal_id) = mcp_http_raw(
      port, read, "{\"jsonrpc\":\"2.0\",\"id\":1.0,\"method\":\"tools/list\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"raw-id-test\",\"version\":\"1\"}}}}",
      "tools/list",
    )
    assert_eq(status, 200)
    assert_true(exact_decimal_id is { "id": Number(1, ..), .. })
    let (status, data) = mcp_http(
      port,
      read,
      { "jsonrpc": "2.0", "id": 1, "method": "tools/list", "params": {} },
      overrides=[("Mcp-Method", "tools/list")],
    )
    assert_eq(status, 400)
    assert_true(data is { "error": { "code": Number(-32602, ..), .. }, .. })
    let (status, _) = mcp_http(
      port,
      read,
      mcp_request("tools/list", { "cursor": Json("bad") }),
    )
    assert_eq(status, 400)
    let (status, data) = mcp_http(
      port,
      read,
      mcp_request("initialize", Map([])),
    )
    assert_eq(status, 404)
    assert_true(data is { "error": { "code": Number(-32601, ..), .. }, .. })
    for value in [Json::null(), Json(true), Json(1.5)] {
      let (status, _) = mcp_http(
        port,
        read,
        mcp_request("tools/list", Map([]), id=value),
      )
      assert_eq(status, 400)
    }
    let (status, data) = mcp_http(
      port,
      read,
      mcp_request("tools/list", Map([]), id=@json.parse("9007199254740993")),
    )
    assert_eq(status, 400)
    assert_true(data is { "error": { "code": Number(-32600, ..), .. }, .. })
    let (status, data) = mcp_http(
      port,
      read,
      mcp_request("tools/list", Map([]), id=Json("9007199254740993")),
    )
    assert_eq(status, 200)
    assert_true(data is { "id": String("9007199254740993"), .. })
    let (status, _) = mcp_http(port, read, [mcp_request("tools/list", Map([]))])
    assert_eq(status, 400)
    for value in ["other", "=?base64?%%%%?="] {
      let (status, _) = mcp_http(
        port,
        read,
        mcp_request("tools/call", { "name": Json("moonhub_get_user") }),
        overrides=[("Mcp-Name", value)],
      )
      assert_eq(status, 400)
    }
    let (status, _) = mcp_http(port, read, mcp_request("tools/list", Map([])))
    assert_eq(status, 200)
  })
}

///|
test "MCP raw IDs distinguish top-level escaped keys nested data and exact decimals" {
  for
    (body, expected) in [
      ("{\"id\":1,\"params\":{\"id\":2}}", Some("1")),
      (
        "{\"params\":{\"id\":2,\"text\":\"}\\\"id\\\":3\"},\"id\":1.0}",
        Some("1.0"),
      ),
      (
        "{\"params\":[{\"id\":2}],\"i\\u0064\":9007199254740992.5}",
        Some("9007199254740992.5"),
      ),
      ("{\"id\":1,\"id\":1.0000000000000001}", Some("1.0000000000000001")),
      ("{\"params\":{\"id\":2}}", None),
    ] {
    assert_eq(raw_request_id_token(body), expected)
  }
  for
    value in [
      "0", "-0", "1.0", "10e-1", "1e+2", "-9007199254740991", "9007199254740991",
    ] {
    assert_true(is_supported_numeric_request_id(value))
  }
  for
    value in [
      "9007199254740992", "-9007199254740992", "9007199254740992.5", "90071992547409925e-1",
      "1.0000000000000001", "1e-9999", "1e9999",
    ] {
    assert_false(is_supported_numeric_request_id(value))
  }
}

///|
async test "MCP rejects rounded fractional numeric IDs before mutations" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let write = @identity.create_access_token(pool, actor, "writer", "write", 1)
    for
      request_id in [
        "9007199254740992.5", "90071992547409925e-1", "1.0000000000000001",
      ] {
      let body = "{\"jsonrpc\":\"2.0\",\"id\":\{request_id},\"method\":\"tools/call\",\"params\":{\"_meta\":{\"io.modelcontextprotocol/protocolVersion\":\"2026-07-28\",\"io.modelcontextprotocol/clientCapabilities\":{},\"io.modelcontextprotocol/clientInfo\":{\"name\":\"raw-id-test\",\"version\":\"1\"}},\"name\":\"moonhub_create_issue\",\"arguments\":{\"repository\":\"alice/demo\",\"title\":\"must not execute\"}}}"
      let (status, data) = mcp_http_raw(
        port,
        write,
        body,
        "tools/call",
        tool_name=Some("moonhub_create_issue"),
      )
      assert_eq(status, 400)
      assert_true(data is { "error": { "code": Number(-32600, ..), .. }, .. })
    }
    let (_, data) = mcp_tool(port, write, "moonhub_list_issues", {
      "repository": Json("alice/demo"),
    })
    assert_true(
      data is { "result": { "structuredContent": { "items": [], .. }, .. }, .. },
    )
  })
}

///|
async test "MCP authentication origin and media checks reject before business operations" {
  @web_testkit.with_repository_test_app((port, pool, _, cookie, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let read = @identity.create_access_token(pool, actor, "mcp", "read", 1)
    let request = mcp_request("tools/list", Map([]))
    let (status, _) = mcp_http(port, "invalid", request)
    assert_eq(status, 401)
    for
      (header, value) in [
        ("Origin", "https://attacker.invalid"),
        ("Origin", "null"),
        ("Sec-Fetch-Site", "cross-site"),
      ] {
      let (status, _) = mcp_http(port, read, request, overrides=[
        (header, value),
      ])
      assert_eq(status, 403)
    }
    let (status, _) = mcp_http(port, read, request, overrides=[
      ("Content-Type", "text/plain"),
    ])
    assert_eq(status, 415)
    let (status, _) = mcp_http(port, read, request, overrides=[
      ("Accept", "application/json"),
    ])
    assert_eq(status, 406)
    let client = @http.Client("http://127.0.0.1:\{port}")
    defer client.close()
    let response = client.post("/-/mcp", request.stringify(), extra_headers={
      "Cookie": "\{cookie.name}=\{cookie.value}",
      "Content-Type": "application/json",
    })
    assert_eq(response.code, 401)
    assert_eq(
      response.headers.get("www-authenticate"),
      Some("Bearer realm=\"moonhub\""),
    )
    client.skip_response_body()
    @identity.revoke_access_token(
      pool,
      actor,
      @identity.access_tokens(pool, actor)[0].id,
    )
    let (status, _) = mcp_http(port, read, request)
    assert_eq(status, 401)
  })
}

///|
async test "MCP issue mutations reuse repository access and optimistic concurrency" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let read = @identity.create_access_token(pool, actor, "reader", "read", 1)
    let write = @identity.create_access_token(pool, actor, "writer", "write", 1)
    let outsider = @identity.create_access_token(
      pool,
      @identity.active_user_by_name(pool, "bob"),
      "outsider",
      "write",
      1,
    )
    let (status, _) = mcp_tool(port, read, "moonhub_create_issue", {
      "repository": Json("alice/demo"),
      "title": Json("denied"),
    })
    assert_eq(status, 403)
    let (status, data) = mcp_tool(port, outsider, "moonhub_create_issue", {
      "repository": Json("alice/demo"),
      "title": Json("denied"),
    })
    assert_eq(status, 200)
    assert_true(data is { "result": { "isError": True, .. }, .. })
    let (status, data) = mcp_tool(port, write, "moonhub_create_issue", {
      "repository": Json("alice/demo"),
      "title": Json("MCP issue"),
      "description": Json("body"),
    })
    assert_eq(status, 200)
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": {
            "number": String("1"),
            "title": String("MCP issue"),
            "edit_version": String("1"),
            ..
          },
          ..
        },
        ..
      },
    )
    let (_, data) = mcp_tool(port, write, "moonhub_edit_issue", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "edit_version": Json("1"),
      "title": Json("Updated"),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": { "edit_version": String("2"), .. },
          ..
        },
        ..
      },
    )
    let (_, stale) = mcp_tool(port, write, "moonhub_close_issue", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "edit_version": Json("1"),
    })
    assert_true(stale is { "result": { "isError": True, .. }, .. })
    let (_, data) = mcp_tool(port, write, "moonhub_close_issue", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "edit_version": Json("2"),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": { "status": String("closed"), .. },
          ..
        },
        ..
      },
    )
    let (_, data) = mcp_tool(port, read, "moonhub_get_issue", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": {
            "issue": { "title": String("Updated"), .. },
            ..
          },
          ..
        },
        ..
      },
    )
    for
      name in [
        "moonhub_create_run", "moonhub_merge_merge_request", "moonhub_approve_merge_checks",
      ] {
      let args : Map[String, Json] = if name == "moonhub_create_run" {
        {
          "repository": Json("alice/demo"),
          "branch": Json("master"),
          "workflow": Json(".github/workflows/test.yml"),
        }
      } else {
        {
          "repository": Json("alice/demo"),
          "number": Json("1"),
          "version": Json("1"),
        }
      }
      let (status, _) = mcp_tool(port, write, name, args)
      assert_eq(status, 403)
    }
  })
}

///|
async test "MCP malformed tool calls and notifications cannot mutate repository state" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let write = @identity.create_access_token(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      "mcp",
      "write",
      1,
    )
    for
      (name, args) in [
        ("unknown", Map([])),
        ("moonhub_create_issue", { "repository": Json("alice/demo") }),
        (
          "moonhub_create_issue",
          { "repository": Json("alice/demo"), "title": Json(1) },
        ),
        (
          "moonhub_create_issue",
          {
            "repository": Json("alice/demo"),
            "title": Json("bad"),
            "admin": Json("true"),
          },
        ),
      ] {
      let (status, data) = mcp_tool(port, write, name, args)
      assert_eq(status, 400)
      assert_true(data is { "error": { "code": Number(-32602, ..), .. }, .. })
    }
    let (status, data) = mcp_http(port, write, {
      "jsonrpc": "2.0",
      "method": "tools/call",
      "params": {
        "name": "moonhub_create_issue",
        "arguments": {
          "repository": "alice/demo",
          "title": "notification must not execute",
        },
      },
    })
    assert_eq(status, 400)
    assert_eq(data, Json::null())
    let (_, data) = mcp_tool(port, write, "moonhub_list_issues", {
      "repository": Json("alice/demo"),
    })
    assert_true(
      data is { "result": { "structuredContent": { "items": [], .. }, .. }, .. },
    )
    for value in ["../demo", "alice/demo/extra", "https://example.com"] {
      let (_, data) = mcp_tool(port, write, "moonhub_list_issues", {
        "repository": Json(value),
      })
      assert_true(data is { "result": { "isError": True, .. }, .. })
    }
  })
}

///|
test "MCP rate limiter bounds per-account requests and expires buckets" {
  let limit : RateLimit = { buckets: Map([]), }
  for i in 0..<120 {
    assert_true(limit.admit(1L, i.to_int64()))
  }
  assert_false(limit.admit(1L, 120L))
  assert_true(limit.admit(2L, 120L))
  assert_true(limit.admit(1L, 60000L))
  let full : RateLimit = { buckets: Map([]), }
  for i in 0..<4096 {
    assert_true(full.admit(i.to_int64(), 0L))
  }
  assert_false(full.admit(4096L, 1L))
  assert_true(full.admit(4096L, 60000L))
  assert_eq(full.buckets.length(), 1)
}

///|
async test "MCP merge requests preserve version guards discussions and execution approval" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let write = @identity.create_access_token(pool, actor, "writer", "write", 1)
    let execute = @identity.create_access_token(
      pool, actor, "executor", "execute", 1,
    )
    let merge = @identity.create_access_token(pool, actor, "merger", "merge", 1)
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let dir = repo.git_dir(root)
    let base = @test_support.workflow_commit(
      dir, @test_support.single_job_workflow,
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", base]))
    ignore(
      @test_support.merge_test_commit(dir, "mcp-feature", base, "feature\n"),
    )
    @collaboration.save_branch_rule(
      pool,
      scope,
      dir,
      actor,
      "master",
      true,
      0L,
      checks=[".github/workflows/build.yml"],
    )
    let (_, data) = mcp_tool(port, write, "moonhub_create_merge_request", {
      "repository": Json("alice/demo"),
      "title": Json("MCP MR"),
      "source": Json("mcp-feature"),
      "target": Json("master"),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": { "number": String("1"), .. },
          ..
        },
        ..
      },
    )
    let mr = @collaboration.require_merge_request(pool, scope, 1L)
    assert_eq(
      @collaboration.merge_checks(pool, mr)[0].state,
      "awaiting_approval",
    )
    for
      name in [
        "moonhub_get_merge_request", "moonhub_get_merge_request_checks", "moonhub_get_merge_request_diff",
        "moonhub_list_merge_discussions",
      ] {
      let (status, data) = mcp_tool(port, write, name, {
        "repository": Json("alice/demo"),
        "number": Json("1"),
      })
      assert_eq(status, 200)
      assert_true(data is { "result": { "isError": False, .. }, .. })
    }
    let (_, data) = mcp_tool(port, write, "moonhub_comment_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "version": Json("1"),
      "body": Json("Review thread"),
    })
    assert_true(data is { "result": { "isError": False, .. }, .. })
    let discussion = @collaboration.list_merge_discussions(
        pool, scope, actor, mr, 1L,
      )[0]
    let (_, data) = mcp_tool(port, write, "moonhub_reply_merge_discussion", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "discussion": Json(discussion.id.to_string()),
      "body": Json("Reply"),
    })
    assert_true(data is { "result": { "isError": False, .. }, .. })
    let (_, data) = mcp_tool(port, write, "moonhub_resolve_merge_discussion", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "discussion": Json(discussion.id.to_string()),
      "state_version": Json(discussion.state_version.to_string()),
    })
    assert_true(data is { "result": { "isError": False, .. }, .. })
    assert_true(
      @collaboration.merge_discussion(pool, scope, actor, mr, discussion.id).resolved,
    )
    let (_, data) = mcp_tool(port, write, "moonhub_reopen_merge_discussion", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "discussion": Json(discussion.id.to_string()),
      "state_version": Json(discussion.state_version.to_string()),
    })
    assert_true(data is { "result": { "isError": True, .. }, .. })
    let (_, data) = mcp_tool(port, write, "moonhub_edit_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "edit_version": Json("1"),
      "title": Json("Updated MR"),
    })
    assert_true(data is { "result": { "isError": False, .. }, .. })
    let (_, data) = mcp_tool(port, write, "moonhub_edit_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "edit_version": Json("1"),
      "title": Json("Stale MR"),
    })
    assert_true(data is { "result": { "isError": True, .. }, .. })
    let (_, data) = mcp_tool(port, merge, "moonhub_merge_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "version": Json("1"),
    })
    assert_true(data is { "result": { "isError": True, .. }, .. })
    let (status, _) = mcp_tool(port, execute, "moonhub_merge_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "version": Json("1"),
    })
    assert_eq(status, 403)
    let (status, _) = mcp_tool(port, merge, "moonhub_approve_merge_checks", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "version": Json("1"),
    })
    assert_eq(status, 403)
    let (_, data) = mcp_tool(port, execute, "moonhub_approve_merge_checks", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "version": Json("99"),
    })
    assert_true(data is { "result": { "isError": True, .. }, .. })
    assert_eq(
      @collaboration.merge_checks(pool, mr)[0].state,
      "awaiting_approval",
    )
    let (_, data) = mcp_tool(port, execute, "moonhub_approve_merge_checks", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "version": Json("1"),
    })
    assert_true(data is { "result": { "isError": False, .. }, .. })
    assert_eq(@collaboration.merge_checks(pool, mr)[0].state, "pending")
    ignore(
      @test_support.merge_test_commit(
        dir,
        "mcp-feature",
        @gitops.branch_sha(dir, "mcp-feature"),
        "new version\n",
      ),
    )
    let (_, data) = mcp_tool(port, merge, "moonhub_merge_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "version": Json("1"),
    })
    assert_true(data is { "result": { "isError": True, .. }, .. })
    assert_eq(@collaboration.require_merge_request(pool, scope, 1L).version, 2L)
    let (_, data) = mcp_tool(port, write, "moonhub_get_merge_request_diff", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "version": Json("1"),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": { "version": String("1"), .. },
          ..
        },
        ..
      },
    )
  })
}

///|
async test "MCP discussion detail returns full context and paginates every reply" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let read = @identity.create_access_token(pool, actor, "reader", "read", 1)
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let dir = repo.git_dir(root)
    let base = @test_support.workflow_commit(
      dir, @test_support.single_job_workflow,
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", base]))
    let long_line = "x".repeat(120)
    let contents = (long_line + "\n").repeat(6)
    ignore(
      @test_support.merge_test_commit(dir, "mcp-discussion", base, contents),
    )
    let mr = @collaboration.create_merge_request(
      pool, scope, dir, actor, "MCP discussion detail", "", "mcp-discussion", "master",
      false,
    )
    let root_body = "R".repeat(700)
    let discussion_id = @collaboration.create_anchored_merge_discussion(
      pool,
      scope,
      actor,
      mr,
      dir,
      1L,
      None,
      "README.md",
      "new",
      1L,
      6L,
      root_body,
    )
    for i in 0..<51 {
      ignore(
        @collaboration.reply_merge_discussion(
          pool,
          scope,
          actor,
          mr,
          discussion_id,
          "reply \{i}",
        ),
      )
    }
    let base_args = {
      "repository": Json("alice/demo"),
      "number": Json(mr.number.to_string()),
    }
    let (_, overview) = mcp_tool(
      port, read, "moonhub_list_merge_discussions", base_args,
    )
    assert_true(
      overview
      is {
        "result": {
          "structuredContent": {
            "items": [
              {
                "root": { "body": String(_), "body_truncated": True, .. },
                "replies": Array(overview_replies),
                "reply_count": String("51"),
                "anchor": {
                  "context": String(_),
                  "context_truncated": True,
                  ..
                },
                ..
              },
            ],
            ..
          },
          ..
        },
        ..
      } &&
      overview_replies.length() == 3,
    )
    let first_page_args = {
      "repository": Json("alice/demo"),
      "number": Json(mr.number.to_string()),
      "discussion": Json(discussion_id.to_string()),
      "page": Json("1"),
    }
    let (_, first_page) = mcp_tool(
      port, read, "moonhub_list_merge_discussions", first_page_args,
    )
    assert_true(
      first_page
      is {
        "result": {
          "structuredContent": {
            "discussion": {
              "root": { "body": String(full_root), "body_truncated": False, .. },
              "replies": Array(first_replies),
              "reply_count": String("51"),
              "anchor": {
                "context": String(full_context),
                "context_truncated": False,
                ..
              },
              ..
            },
            "has_more": True,
            ..
          },
          ..
        },
        ..
      } &&
      full_root == root_body &&
      full_context.iter().count() > 512 &&
      first_replies.length() == 50 &&
      first_replies[0] is { "body": String("reply 0"), .. },
    )
    let second_page_args = {
      "repository": Json("alice/demo"),
      "number": Json(mr.number.to_string()),
      "discussion": Json(discussion_id.to_string()),
      "page": Json("2"),
    }
    let (_, second_page) = mcp_tool(
      port, read, "moonhub_list_merge_discussions", second_page_args,
    )
    assert_true(
      second_page
      is {
        "result": {
          "structuredContent": {
            "discussion": {
              "replies": [{ "body": String("reply 50"), .. }],
              ..
            },
            "has_more": False,
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
async test "MCP CI tools create query cancel rerun and reject out of scope log reads" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let execute = @identity.create_access_token(
      pool, actor, "executor", "execute", 1,
    )
    let outsider = @identity.create_access_token(
      pool,
      @identity.active_user_by_name(pool, "bob"),
      "outsider",
      "read",
      1,
    )
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let dir = repo.git_dir(root)
    let base = @test_support.workflow_commit(
      dir, @test_support.single_job_workflow,
    )
    ignore(@gitops.merge_git(dir, ["update-ref", "refs/heads/master", base]))
    let (_, data) = mcp_tool(port, execute, "moonhub_create_run", {
      "repository": Json("alice/demo"),
      "branch": Json("master"),
      "workflow": Json(".github/workflows/build.yml"),
    })
    guard data
      is {
        "result": {
          "isError": False,
          "structuredContent": { "number": String(number), .. },
          ..
        },
        ..
      } else {
      fail("run missing")
    }
    let coordinator = @pipeline.Coordinator::new(pool)
    let provider_token = @identity.random_hex(32)
    let attempt_token = @identity.random_hex(32)
    ignore(
      coordinator.create_provider(
        @identity.active_user_by_name(pool, "admin"),
        "mcp-test-provider",
        provider_token,
        ["self-hosted", "linux"],
        [repo],
      ),
    )
    let assignment = coordinator
      .claim(provider_token, {
        version: 1,
        runner_os: None,
        request_id: @identity.random_hex(16),
        attempt_token,
      })
      .unwrap()
    let attempt = decimal(assignment.attempt_id)
    ignore(coordinator.start(attempt, attempt_token, 1))
    ignore(
      coordinator.append_log(attempt, attempt_token, {
        version: 1,
        sequence: "1",
        step_id: "check",
        stream: "stdout",
        text: "MCP log output\n",
      }),
    )
    let (_, logs) = mcp_tool(port, execute, "moonhub_get_run_logs", {
      "repository": Json("alice/demo"),
      "number": Json(number),
      "attempt": Json(assignment.attempt_id),
    })
    assert_true(
      logs
      is {
        "result": {
          "isError": False,
          "structuredContent": {
            "chunks": [{ "text": String("MCP log output\n"), .. }],
            "has_more": False,
            "complete": False,
            ..
          },
          ..
        },
        ..
      },
    )
    let (_, data) = mcp_tool(port, execute, "moonhub_get_run", {
      "repository": Json("alice/demo"),
      "number": Json(number),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": {
            "run": {
              "context": { "event_name": String("workflow_dispatch"), .. },
              ..
            },
            "jobs": [_, ..],
            ..
          },
          ..
        },
        ..
      },
    )
    let (_, data) = mcp_tool(port, execute, "moonhub_list_runs", {
      "repository": Json("alice/demo"),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": { "items": [_, ..], .. },
          ..
        },
        ..
      },
    )
    let (_, data) = mcp_tool(port, outsider, "moonhub_get_run_logs", {
      "repository": Json("alice/demo"),
      "number": Json(number),
      "attempt": Json("1"),
    })
    assert_true(data is { "result": { "isError": True, .. }, .. })
    let (_, data) = mcp_tool(port, execute, "moonhub_get_run_logs", {
      "repository": Json("alice/demo"),
      "number": Json(number),
      "attempt": Json("999"),
    })
    assert_true(data is { "result": { "isError": True, .. }, .. })
    let (_, data) = mcp_tool(port, execute, "moonhub_cancel_run", {
      "repository": Json("alice/demo"),
      "number": Json(number),
    })
    assert_true(data is { "result": { "isError": False, .. }, .. })
    let (_, pending) = mcp_tool(port, execute, "moonhub_rerun_run", {
      "repository": Json("alice/demo"),
      "number": Json(number),
    })
    assert_true(pending is { "result": { "isError": True, .. }, .. })
    ignore(
      coordinator.complete(attempt, attempt_token, {
        version: 1,
        conclusion: "cancelled",
        last_log_sequence: "1",
      }),
    )
    let (_, data) = mcp_tool(port, execute, "moonhub_rerun_run", {
      "repository": Json("alice/demo"),
      "number": Json(number),
    })
    assert_true(data is { "result": { "isError": False, .. }, .. })
  })
}

///|
async test "MCP HTTP handles unsupported methods malformed JSON and oversized bodies" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let token = @identity.create_access_token(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      "mcp",
      "read",
      1,
    )
    for verb in [@http.Get, @http.Delete] {
      let client = @http.Client("http://127.0.0.1:\{port}")
      defer client.close()
      client.request(verb, "/-/mcp")
      let response = client.end_request()
      assert_eq(response.code, 405)
      assert_eq(response.headers.get("allow"), Some("POST"))
      client.skip_response_body()
    }
    for body in ["{", " ".repeat(65537)] {
      let client = @http.Client("http://127.0.0.1:\{port}")
      defer client.close()
      let response = client.post("/-/mcp", body, extra_headers={
        "Authorization": "Bearer " + token,
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
      })
      assert_eq(response.code, 400)
      let result = @json.parse(client.read_all().text())
      assert_true(result is { "error": Object(_), .. })
    }
  })
}

///|
async test "MCP explicit origin policy and rate limits are isolated per application" {
  @web_testkit.with_repository_test_app((_, pool, root, _, _) => {
    let token = @identity.create_access_token(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      "mcp",
      "read",
      1,
    )
    let fixture_module : @moonback.Module = Module(ctx => {
      ctx.provide(@web_context.config_db_pool, pool)
      ctx.provide(@web_context.config_root, root)
      ctx.provide(
        @web_context.pipeline_coordinator_key,
        @pipeline.Coordinator::new(pool),
      )
      ctx.provide(allowed_origins_key, ["https://trusted.example"])
      ctx.use_(mcp_module)
    })
    let first = @moonback.App(
      Module(ctx => ctx.mount("/-/mcp", App(fixture_module))),
    )
    defer first.close()
    let second = @moonback.App(
      Module(ctx => ctx.mount("/-/mcp", App(fixture_module))),
    )
    defer second.close()
    @async.with_task_group(group => {
      let listener = @moonback.listen(port=0)
      let server = group.spawn(() => first.serve(listener))
      defer server.cancel()
      let other_listener = @moonback.listen(port=0)
      let other_server = group.spawn(() => second.serve(other_listener))
      defer other_server.cancel()
      let request = mcp_request("server/discover", Map([]))
      let (status, _) = mcp_http(listener.addr.port(), token, request, overrides=[
        ("Origin", "https://trusted.example"),
        ("Sec-Fetch-Site", "cross-site"),
      ])
      assert_eq(status, 200)
      let (status, _) = mcp_http(listener.addr.port(), token, request, overrides=[
        ("Origin", "https://trusted.example, https://evil.example"),
      ])
      assert_eq(status, 403)
      for _ in 1..<120 {
        assert_eq(mcp_http(listener.addr.port(), token, request).0, 200)
      }
      assert_eq(mcp_http(listener.addr.port(), token, request).0, 429)
      assert_eq(mcp_http(other_listener.addr.port(), token, request).0, 200)
    })
  })
}

///|
async test "MCP propagates redacted internal errors instead of business-error results" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let token = @identity.create_access_token(
      pool,
      @identity.active_user_by_name(pool, "alice"),
      "mcp",
      "write",
      1,
    )
    pool.with_client(client => {
      ignore(
        client.execute(
          "CREATE TEMP TRIGGER mcp_test_failure BEFORE INSERT ON issue BEGIN SELECT RAISE(ABORT, 'private-secret-database-path'); END",
        ),
      )
    })
    let (status, result) = mcp_tool(port, token, "moonhub_create_issue", {
      "repository": Json("alice/demo"),
      "title": Json("Should roll back"),
    })
    assert_eq(status, 500)
    assert_true(result is { "error": { "code": Number(-32603, ..), .. }, .. })
    assert_false(result.stringify().contains("private-secret"))
    let (_, result) = mcp_tool(port, token, "moonhub_list_issues", {
      "repository": Json("alice/demo"),
    })
    assert_true(
      result
      is { "result": { "structuredContent": { "items": [], .. }, .. }, .. },
    )
  })
}

///|
async test "MCP merge submission requires the merge scope and creates the existing merge job" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let merge = @identity.create_access_token(pool, actor, "merger", "merge", 1)
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let dir = repo.git_dir(root)
    ignore(
      @test_support.merge_test_commit(
        dir,
        "mcp-merge",
        @gitops.branch_sha(dir, "master"),
        "merge\n",
      ),
    )
    let (_, data) = mcp_tool(port, merge, "moonhub_create_merge_request", {
      "repository": Json("alice/demo"),
      "title": Json("Merge me"),
      "source": Json("mcp-merge"),
      "target": Json("master"),
    })
    assert_true(data is { "result": { "isError": False, .. }, .. })
    let (status, data) = mcp_tool(port, merge, "moonhub_merge_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "version": Json("1"),
    })
    assert_eq(status, 200)
    assert_true(data is { "result": { "isError": False, .. }, .. })
    assert_true(@collaboration.run_next_merge_job(pool, root))
    assert_eq(
      @collaboration.require_merge_request(pool, scope, 1L).status,
      "merged",
    )
  })
}
