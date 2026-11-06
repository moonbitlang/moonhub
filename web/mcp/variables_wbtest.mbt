///|
test "MCP variables distinguish read access from management and expose scalar schema" {
  let list = tool_catalog()
    .iter()
    .find_first(tool => tool.name == "moonhub_list_variables")
    .unwrap()
  assert_eq(list.permission, "read")
  assert_true(
    list.definition() is { "annotations": { "readOnlyHint": True, .. }, .. },
  )
  for name in ["moonhub_set_variable", "moonhub_delete_variable"] {
    let tool = tool_catalog()
      .iter()
      .find_first(tool => tool.name == name)
      .unwrap()
    assert_eq(tool.permission, "write")
    assert_true(tool.description.contains("owner/admin"))
  }
  let save = tool_catalog()
    .iter()
    .find_first(tool => tool.name == "moonhub_set_variable")
    .unwrap()
  save.validate({
    "repository": "alice/demo",
    "name": "REGION",
    "value": "",
    "version": "0",
  })
  try
    save.validate({
      "repository": "alice/demo",
      "name": "REGION",
      "value": false,
      "version": "0",
    })
  catch {
    ProtocolError(400, -32602, _, _) => ()
    err => raise err
  } noraise {
    _ => fail("accepted nonstring variable")
  }
}

///|
async test "MCP variable tools read values and enforce permissions and observed revisions" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let read = @identity.create_access_token(pool, actor, "read", "read", 1)
    let write = @identity.create_access_token(pool, actor, "write", "write", 1)
    let outside = @identity.create_access_token(
      pool, bob, "outside", "write", 1,
    )
    let args : Map[String, Json] = {
      "repository": "alice/demo",
      "name": "region",
      "value": "us-west-2",
      "version": "0",
    }
    assert_eq(mcp_tool(port, read, "moonhub_set_variable", args).0, 403)
    let (_, denied) = mcp_tool(port, outside, "moonhub_set_variable", args)
    assert_true(denied is { "result": { "isError": True, .. }, .. })
    let (status, saved) = mcp_tool(port, write, "moonhub_set_variable", args)
    assert_eq(status, 200)
    guard saved
      is {
        "result": {
          "structuredContent": {
            "name": String("REGION"),
            "value": String("us-west-2"),
            "version": String(version),
            ..
          },
          "isError": False,
          ..
        },
        ..
      } else {
      fail("missing variable result")
    }
    let (_, listed) = mcp_tool(port, read, "moonhub_list_variables", {
      "repository": "alice/demo",
    })
    assert_true(listed.stringify().contains("us-west-2"))
    let (_, stale) = mcp_tool(port, write, "moonhub_set_variable", args)
    assert_true(stale is { "result": { "isError": True, .. }, .. })
    let (_, empty) = mcp_tool(port, write, "moonhub_set_variable", {
      "repository": "alice/demo",
      "name": "region",
      "value": "",
      "version": version,
    })
    guard empty
      is {
        "result": {
          "structuredContent": {
            "value": String(""),
            "version": String(latest),
            ..
          },
          ..
        },
        ..
      } else {
      fail("missing empty value")
    }
    let (_, removed) = mcp_tool(port, write, "moonhub_delete_variable", {
      "repository": "alice/demo",
      "name": "region",
      "version": latest,
    })
    assert_true(
      removed
      is {
        "result": {
          "structuredContent": { "ok": True, .. },
          "isError": False,
          ..
        },
        ..
      },
    )
  })
}

///|
async test "MCP variable save accepts bounded escaped payload without widening other tools" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let token = @identity.create_access_token(pool, actor, "vars", "write", 1)
    let value = "\u{0001}".repeat(40000) + "x".repeat(9152)
    let (status, saved) = mcp_tool(port, token, "moonhub_set_variable", {
      "repository": "alice/demo",
      "name": "PAYLOAD",
      "value": value,
      "version": "0",
    })
    assert_eq(status, 200)
    guard saved
      is {
        "result": {
          "structuredContent": {
            "value": String(actual),
            "version": String(version),
            ..
          },
          "isError": False,
          ..
        },
        ..
      } else {
      fail("missing maximum value")
    }
    assert_eq(actual, value)
    let (_, invalid) = mcp_tool(port, token, "moonhub_set_variable", {
      "repository": "alice/demo",
      "name": "PAYLOAD",
      "value": value + "x",
      "version": version,
    })
    assert_true(invalid is { "result": { "isError": True, .. }, .. })
    let (oversized, error) = mcp_tool(port, token, "moonhub_set_variable", {
      "repository": "alice/demo",
      "name": "PAYLOAD",
      "value": "x".repeat(327680),
      "version": version,
    })
    assert_eq(oversized, 400)
    assert_true(error.stringify().contains("request body is too large"))
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
    assert_true(error.stringify().contains("request body is too large"))
  })
}

///|
async test "variable MCP larger body allowance cannot be claimed by mismatched tool metadata" {
  @web_testkit.with_repository_test_app((port, pool, _, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let token = @identity.create_access_token(pool, actor, "vars", "write", 1)
    let request = mcp_request("tools/call", {
      "name": "moonhub_get_user",
      "arguments": {},
    })
    let (status, error) = mcp_http(port, token, request, overrides=[
      ("Mcp-Name", "moonhub_set_variable"),
    ])
    assert_eq(status, 400)
    assert_true(error is { "error": Object(_), .. })
  })
}
