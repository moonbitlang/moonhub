///|
test "provider CLI scope defaults are conservative and ensure can preserve scope" {
  for command in ["pipeline-provider-create", "pipeline-provider-ensure"] {
    let args = [command, "--name", "dind", "--token-file", "/token"]
    let (_, options) = management_command().parse(argv=args).subcommand.unwrap()
    assert_eq(
      single_value(options, "scope"),
      if command == "pipeline-provider-create" {
        Some("selected")
      } else {
        None
      },
    )
    for scope in ["selected", "all"] {
      let (_, options) = management_command().parse(
        argv=args + ["--scope", scope],
      ).subcommand.unwrap()
      assert_eq(single_value(options, "scope"), Some(scope))
    }
  }
}

///|
async test "provider management CLI forwards explicit scope and preserves omitted scope" {
  @test_support.with_git_test_repo((root, _) => {
    let db = root + "/provider-cli.db"
    let token = root + "/token"
    @fs.write_file(token, "a".repeat(64), permission=0o600)
    @async.with_task_group(group => {
      let pool = @database.new_db_pool({ path: db, }, group)
      defer pool.close()
      @database.initialize_db(pool)
      pool.with_client(client => {
        client.batch_execute(
          (
            #|INSERT INTO "user" (id, name_key, display_name, password_hash, is_site_admin)
            #|VALUES (1, 'admin', 'Admin', 'test', 1);
            #|INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'admin', 'Admin', 'personal');
            #|INSERT INTO repository (team_id, name, visibility) VALUES (1, 'demo', 'private');
          ),
        )
      })
      let actor = @identity.active_user_by_name(pool, "admin")
      let coordinator = @pipeline.Coordinator::new(pool)
      let options = [
        "--db", db, "--name", "cli", "--token-file", token, "--admin", "admin",
      ]
      assert_eq(run_management_cli(["pipeline-provider-create"] + options), 0)
      assert_eq(coordinator.list_providers(actor)[0].scope.value(), "selected")
      assert_true(coordinator.list_providers(actor)[0].repositories.is_empty())
      let ensure = ["pipeline-provider-ensure"] + options
      assert_eq(run_management_cli(ensure + ["--scope", "all"]), 0)
      assert_eq(coordinator.list_providers(actor)[0].scope.value(), "all")
      assert_eq(run_management_cli(ensure), 0)
      assert_eq(coordinator.list_providers(actor)[0].scope.value(), "all")
      assert_eq(
        run_management_cli(
          ensure + ["--preserve-existing", "--scope", "selected"],
        ),
        0,
      )
      assert_eq(coordinator.list_providers(actor)[0].scope.value(), "all")
      assert_eq(
        run_management_cli(
          ensure + ["--scope", "selected", "--repositories", "admin/demo"],
        ),
        0,
      )
      assert_eq(coordinator.list_providers(actor)[0].scope.value(), "selected")
      assert_eq(coordinator.list_providers(actor)[0].repositories, [
        "admin/demo",
      ])
      for
        invalid in [
          ["--scope", "invalid"],
          ["--scope", "all", "--repositories", "admin/demo"],
        ] {
        try run_management_cli(ensure + invalid) catch {
          @domain.BadRequest(_) => ()
          err => raise err
        } noraise {
          _ => fail("invalid scope was accepted")
        }
        assert_eq(
          coordinator.list_providers(actor)[0].scope.value(),
          "selected",
        )
        assert_eq(coordinator.list_providers(actor)[0].repositories, [
          "admin/demo",
        ])
      }
      @fs.write_file(token, "b".repeat(64), permission=0o600)
      assert_eq(
        run_management_cli([
          "pipeline-provider-create", "--db", db, "--name", "shared", "--token-file",
          token, "--admin", "admin", "--scope", "all",
        ]),
        0,
      )
      assert_eq(coordinator.list_providers(actor)[1].scope.value(), "all")
    })
  })
}
