///|
test "MCP discovery describes closing directives preview and link-only issue argument" {
  for
    name in [
      "moonhub_create_merge_request", "moonhub_edit_merge_request", "moonhub_get_merge_request",
      "moonhub_merge_merge_request",
    ] {
    let tool = tool_catalog().filter(tool => tool.name == name)[0]
    guard tool.definition() is { "description": String(description), .. } else {
      fail("missing tool description")
    }
    assert_true(description.contains("closing_issue_numbers"), msg=name)
    assert_true(description.contains("merge"), msg=name)
    if name == "moonhub_create_merge_request" ||
      name == "moonhub_edit_merge_request" {
      guard tool.definition()
        is {
          "inputSchema": {
            "properties": {
              "description": { "description": String(help), .. },
              ..
            },
            ..
          },
          ..
        } else {
        fail("missing description schema help")
      }
      assert_true(help.contains("Closes #123"))
    }
    if name == "moonhub_create_merge_request" {
      guard tool.definition()
        is {
          "inputSchema": {
            "properties": { "issue": { "description": String(help), .. }, .. },
            ..
          },
          ..
        } else {
        fail("missing related issue schema help")
      }
      assert_true(help.contains("only links"))
    }
  }
}

///|
async test "MCP agents can discover declare preview edit and confirm merge closures" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let token = @identity.create_access_token(
      pool, actor, "closures", "merge", 1,
    )
    let scope = @repository.repository_scope(pool, actor, {
      owner: "alice",
      name: "demo",
    })
    let first = @collaboration.create_issue(pool, scope, actor, "First", "", 0L)
    let second = @collaboration.create_issue(
      pool, scope, actor, "Second", "", 0L,
    )
    let dir = "\{root}/alice/demo.git"
    ignore(
      @test_support.merge_test_commit(
        dir,
        "closing",
        @gitops.branch_sha(dir, "master"),
        "fix\n",
      ),
    )
    let (_, data) = mcp_tool(port, token, "moonhub_create_merge_request", {
      "repository": Json("alice/demo"),
      "title": Json("Fix"),
      "source": Json("closing"),
      "target": Json("master"),
      "description": Json("Closes #\{first}"),
      "issue": Json(second.to_string()),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": { "closing_issue_numbers": [String("1")], .. },
          ..
        },
        ..
      },
    )
    let (_, data) = mcp_tool(port, token, "moonhub_edit_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "edit_version": Json("1"),
      "description": Json("Resolves #\{second}"),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": { "closing_issue_numbers": [String("2")], .. },
          ..
        },
        ..
      },
    )
    let (_, data) = mcp_tool(port, token, "moonhub_get_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": {
            "mr": { "closing_issue_numbers": [String("2")], .. },
            ..
          },
          ..
        },
        ..
      },
    )
    let (_, data) = mcp_tool(port, token, "moonhub_merge_merge_request", {
      "repository": Json("alice/demo"),
      "number": Json("1"),
      "version": Json("1"),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": { "closing_issue_numbers": [String("2")], .. },
          ..
        },
        ..
      },
    )
    assert_eq(@collaboration.require_issue(pool, scope, second).status, "open")
    assert_true(@collaboration.run_next_merge_job(pool, root))
    let (_, data) = mcp_tool(port, token, "moonhub_get_issue", {
      "repository": Json("alice/demo"),
      "number": Json(second.to_string()),
    })
    assert_true(
      data
      is {
        "result": {
          "isError": False,
          "structuredContent": {
            "issue": { "status": String("closed"), .. },
            ..
          },
          ..
        },
        ..
      },
    )
    assert_eq(@collaboration.require_issue(pool, scope, first).status, "open")
  })
}
