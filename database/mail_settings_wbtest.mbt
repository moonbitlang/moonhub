///|
async test "baseline defaults mail settings and preserves SSH settings" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO site_settings (id, ssh_public_host, ssh_public_port) VALUES (1, 'git.example.com', 2222);
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    assert_eq(
      @repository.effective_ssh_endpoint(
        pool, @repository.no_ssh_address_config,
      )
      .unwrap()
      .authority(),
      "git.example.com:2222",
    )
    assert_eq(@mail.load_mail_settings(pool).transport, "file")
    assert_eq(@mail.load_mail_settings(pool).smtp.port, 587)
    pool.with_client(client => {
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
    })
  })
}
