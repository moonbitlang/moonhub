///|
async test "MCP repository tools share namespace permissions and provisioning metadata" {
  @web_testkit.with_repository_test_app((port, pool, root, _, _) => {
    let alice = @identity.active_user_by_name(pool, "alice")
    let bob = @identity.active_user_by_name(pool, "bob")
    let read = @identity.create_access_token(pool, alice, "reader", "read", 1)
    let write = @identity.create_access_token(pool, alice, "writer", "write", 1)
    let outsider = @identity.create_access_token(
      pool, bob, "outside", "write", 1,
    )
    @repository.save_ssh_endpoint(
      pool,
      @identity.active_user_by_name(pool, "admin"),
      @repository.no_ssh_address_config,
      "git.example.test",
      "2222",
    )
    let create = "moonhub_create_repository"
    let view = "moonhub_get_repository"
    let args : Map[String, Json] = { "repository": Json("alice/mcp-demo") }
    assert_eq(mcp_tool(port, read, create, args).0, 403)
    let (status, denied) = mcp_tool(port, outsider, create, args)
    assert_eq(status, 200)
    assert_true(denied is { "result": { "isError": True, .. }, .. })
    assert_eq(
      mcp_tool(port, write, create, {
        "repository": Json("alice/mcp-demo"),
        "source_url": Json("ssh://git.example.test/alice/other.git"),
      }).0,
      400,
    )
    let (status, created) = mcp_tool(port, write, create, args)
    assert_eq(status, 200)
    assert_true(
      created
      is {
        "result": {
          "structuredContent": {
            "full_name": String("alice/mcp-demo"),
            "visibility": String("private"),
            "state": String("pending"),
            "default_branch": Null,
            "clone_url": String(
              "ssh://git@git.example.test:2222/alice/mcp-demo.git",
            ),
            ..
          },
          "isError": False,
          ..
        },
        ..
      },
    )
    let (_, pending) = mcp_tool(port, read, view, args)
    assert_true(
      pending
      is {
        "result": {
          "structuredContent": { "state": String("pending"), .. },
          ..
        },
        ..
      },
    )
    assert_true(@repository.run_next_repository_job(pool, root, None))
    let (_, ready) = mcp_tool(port, read, view, args)
    assert_true(
      ready
      is {
        "result": {
          "structuredContent": {
            "state": String("ready"),
            "default_branch": String("main"),
            ..
          },
          ..
        },
        ..
      },
    )
    let (_, hidden) = mcp_tool(port, outsider, view, args)
    assert_true(hidden is { "result": { "isError": True, .. }, .. })
  })
}
