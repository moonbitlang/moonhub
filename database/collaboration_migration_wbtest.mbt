///|
async test "collaboration migration upgrades schema three without losing repositories or jobs" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    for
      file in [
        "db/base.sql", "db/migrations/001_ssh_keys.sql", "db/migrations/002_repository_jobs.sql",
        "db/migrations/003_ssh_addresses.sql",
      ] {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user" (id, name_key, display_name, password_hash) VALUES (1, 'existing', 'Existing', 'hash');
          #|INSERT INTO team (id, name_key, display_name, kind) VALUES (1, 'existing', 'Existing', 'personal');
          #|INSERT INTO team_member (team_id, user_id, role) VALUES (1, 1, 'owner');
          #|INSERT INTO repository (id, team_id, name, ready) VALUES (1, 1, 'repo', 1);
          #|INSERT INTO repository_job (repository_id, requested_by_user_id, status) VALUES (1, 1, 'succeeded');
          #|INSERT INTO site_settings (id, ssh_public_host, ssh_public_port) VALUES (1, 'git.example.com', 2222);
          #|PRAGMA user_version = 3;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    let user = @identity.active_user_by_name(pool, "existing")
    let scope = @repository.repository_scope(pool, user, {
      owner: "existing",
      name: "repo",
    })
    assert_eq(
      @collaboration.create_issue(pool, scope, user, "Migration", "", user.id),
      1L,
    )
    let job = @repository.require_repository_job(
      pool,
      @identity.get_team_by_name_key(pool, "existing").unwrap(),
      "repo",
    )
    assert_eq(job.status, "succeeded")
    assert_eq(
      @repository.effective_ssh_endpoint(
        pool, @repository.no_ssh_address_config,
      )
      .unwrap()
      .authority(),
      "git.example.com:2222",
    )
    assert_true(
      pool.with_client(client => {
        client.query_all("PRAGMA foreign_key_check").is_empty()
      }),
    )
  })
}
