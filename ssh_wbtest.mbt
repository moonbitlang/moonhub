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
