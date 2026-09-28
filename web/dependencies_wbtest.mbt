///|
async test "feature modules fail during initialization when assets are not injected" {
  for
    module_ in [
      @auth_views.auth_module, @account_views.profile_module, @account_views.ssh_keys_module,
      @settings_views.site_settings_module, @repository_views.index_module, @namespace_views.teams_module,
      @namespace_views.namespaces_module, @repository_views.repositories_module,
      @repository_views.deploy_keys_module, @merge_request_views.merge_requests_module,
      @issue_views.issues_module, @repository_views.repo_browser_module,
    ] {
    try {
      let app = @moonback.App(module_)
      app.close()
    } catch {
      @moonback.MissingDependency(name~) =>
        assert_eq(name, "moonhub.asset_paths")
      err => raise err
    } noraise {
      _ => fail("module accepted missing assets")
    }
  }
}

///|
async test "feature modules require the injected database rather than bootstrap config" {
  @test_support.with_ssh_test_db(pool => {
    try {
      let app = @moonback.App(
        Module(ctx => {
          ctx.provide(@web_context.asset_paths_key, Map([]))
          ctx.use_(@account_views.profile_module)
        }),
        config=Config(custom=[
          @moonback.Config::custom(@web_context.config_db_pool, pool),
        ]),
      )
      app.close()
    } catch {
      @moonback.MissingDependency(name~) => assert_eq(name, "moonhub.db_pool")
      err => raise err
    } noraise {
      _ => fail("module read a dependency directly from bootstrap config")
    }
    let app = @moonback.App(
      Module(ctx => {
        ctx.provide(@web_context.asset_paths_key, Map([]))
        ctx.provide(@web_context.config_db_pool, pool)
        ctx.use_(@account_views.profile_module)
      }),
    )
    defer app.close()
  })
}

///|
async test "browser modules require an explicit repository access policy" {
  try {
    let app = @moonback.App(
      Module(ctx => {
        ctx.provide(@web_context.asset_paths_key, Map([]))
        ctx.provide(@web_context.config_root, @web_testkit.test_repo_root)
        ctx.use_(@repository_views.repo_browser_module)
      }),
    )
    app.close()
  } catch {
    @moonback.MissingDependency(name~) =>
      assert_eq(name, "moonhub.browser_access")
    err => raise err
  } noraise {
    _ => fail("browser initialized without authorization policy")
  }
}

///|
async test "injected browser resources stay isolated between applications" {
  let first = @moonback.App(
    Module(ctx => {
      ctx.provide(@web_context.asset_paths_key, { "instance": "first" })
      ctx.use_(
        @moonback.Module(child => {
          assert_eq(
            child.require(@web_context.asset_paths_key)["instance"],
            "first",
          )
        }),
      )
    }),
  )
  defer first.close()
  let second = @moonback.App(
    Module(ctx => {
      assert_true(ctx.resolve(@web_context.asset_paths_key) is None)
      ctx.provide(@web_context.asset_paths_key, { "instance": "second" })
      assert_eq(ctx.require(@web_context.asset_paths_key)["instance"], "second")
    }),
  )
  defer second.close()
}

///|
async test "service initialization publishes optional import settings and SSH defaults" {
  @test_support.with_ssh_test_db(pool => {
    let app = @moonback.App(
      Module(ctx => {
        ctx.provide(@web_context.config_root, @web_testkit.test_repo_root)
        ctx.use_(services_module)
        assert_true(ctx.resolve(@web_context.config_repo_import) is None)
        assert_true(
          ctx.require(@web_context.config_ssh_addresses).public_override is None,
        )
        assert_true(
          ctx.require(@web_context.config_ssh_addresses).internal is None,
        )
        assert_true(ctx.resolve(@web_context.browser_access_key) is Some(_))
      }),
      config=Config(custom=[
        @moonback.Config::custom(@web_context.config_db_pool, pool),
      ]),
    )
    defer app.close()
    let configured = @moonback.App(
      Module(ctx => {
        ctx.provide(@web_context.config_root, @web_testkit.test_repo_root)
        ctx.use_(services_module)
        assert_eq(ctx.require(@web_context.config_repo_import).timeout_ms, 1234)
        assert_eq(
          ctx.require(@web_context.config_ssh_addresses).internal,
          Some({ host: "ssh", port: 2222, }),
        )
      }),
      config=Config(custom=[
        @moonback.Config::custom(@web_context.config_db_pool, pool),
        @moonback.Config::custom(@web_context.config_repo_import, {
          credentials_root: "/credentials",
          ssh_wrapper: "/ssh-wrapper",
          timeout_ms: 1234,
        }),
        @moonback.Config::custom(@web_context.config_ssh_addresses, {
          public_override: None,
          internal: Some({ host: "ssh", port: 2222, }),
        }),
      ]),
    )
    defer configured.close()
  })
}
