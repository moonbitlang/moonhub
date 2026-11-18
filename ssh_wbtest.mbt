///|
test "SSH read timeouts default and explicit options override environment" {
  for
    (args, env, idle, maximum) in [
      (["ssh-serve", "1"], {}, 120, 3600),
      (
        ["ssh-serve", "1"],
        {
          "MOONHUB_SSH_READ_IDLE_TIMEOUT_SECONDS": "1",
          "MOONHUB_SSH_READ_MAX_SECONDS": "2147483",
        },
        1,
        2147483,
      ),
      (
        [
          "ssh-serve", "1", "--read-idle-timeout-seconds", "15", "--read-max-seconds",
          "60",
        ],
        {
          "MOONHUB_SSH_READ_IDLE_TIMEOUT_SECONDS": "invalid",
          "MOONHUB_SSH_READ_MAX_SECONDS": "0",
        },
        15,
        60,
      ),
    ] {
    let (_, options) = management_command().parse(argv=args, env~).subcommand.unwrap()
    assert_eq(ssh_read_seconds(options, "read-idle-timeout-seconds"), idle)
    assert_eq(ssh_read_seconds(options, "read-max-seconds"), maximum)
  }
  for
    (name, variable) in [
      ("read-idle-timeout-seconds", "MOONHUB_SSH_READ_IDLE_TIMEOUT_SECONDS"),
      ("read-max-seconds", "MOONHUB_SSH_READ_MAX_SECONDS"),
    ] {
    for
      value in [
        "", "0", "-1", "+1", "1.5", " 1", "1\n", "2147484", "2147483648", "9999999999999999999999999999999999999",
      ] {
      for from_env in [true, false] {
        let env : Map[String, String] = Map([])
        let args = ["ssh-serve", "1"]
        if from_env {
          env[variable] = value
        } else {
          args.push("--\{name}=\{value}")
        }
        let (_, options) = management_command().parse(argv=args, env~).subcommand.unwrap()
        try ignore(ssh_read_seconds(options, name)) catch {
          @domain.BadRequest(_) => ()
          err => raise err
        } noraise {
          _ => fail("accepted invalid SSH read timeout")
        }
      }
    }
  }
}

///|
test "management commands inherit deployment settings and parse key identifiers" {
  let parsed = management_command().parse(
    argv=["repo-create", "alice/demo", "--import", "--visibility", "public"],
    env={ "DB_PATH": "/data/moonhub.db", "MOONHUB_REPO_ROOT": "/data/repos" },
  )
  assert_eq(cli_value(parsed, "db"), "/data/moonhub.db")
  assert_eq(cli_value(parsed, "root"), "/data/repos")
  let (_, options) = parsed.subcommand.unwrap()
  assert_eq(cli_value(options, "repository"), "alice/demo")
  assert_true(options.flags["import"])
  assert_eq(cli_value(options, "visibility"), "public")
}

///|
async test "create and import register only managed bare repositories" {
  @test_support.with_ssh_test_db(pool => {
    @test_support.with_git_test_repo((root, _) => {
      @repository.create_managed_repository(
        pool,
        root,
        { owner: "bob", name: "new", },
        "private",
        false,
      )
      assert_true(@fs.exists("\{root}/bob/new.git/HEAD"))
      assert_eq(@gitops.default_ref("\{root}/bob/new.git"), "main")
      assert_true(
        @repository.can_access_repository(
          pool,
          @identity.active_user_by_name(pool, "bob"),
          { owner: "bob", name: "new", },
          @repository.Write,
        ),
      )
      pool.with_client(client => {
        let _ = client.execute("DELETE FROM repository WHERE name = 'demo'")
      })
      @repository.create_managed_repository(
        pool,
        root,
        { owner: "alice", name: "demo", },
        "private",
        true,
      )
      assert_eq(
        @gitops.list_commits("\{root}/alice/demo.git", "master").length(),
        1,
      )
    })
  })
}
