///|
async test "image attachment migration preserves collaboration and reinitializes safely" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    attachment_upgrade_fixture(pool, 21)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user"(id,name_key,display_name,password_hash) VALUES(1,'alice','Alice','hash');
          #|INSERT INTO team(id,name_key,display_name,kind) VALUES(1,'alice','Alice','personal');
          #|INSERT INTO repository(id,team_id,name) VALUES(1,1,'demo');
          #|INSERT INTO issue(id,repository_id,number,author_id,title,description) VALUES(1,1,1,1,'Existing','Keep this');
          #|PRAGMA user_version=21;
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
      assert_eq(
        (
          client
          .query_one("SELECT description FROM issue WHERE id=1")
          .get_name("description") : String),
        "Keep this",
      )
      assert_true(client.query_all("SELECT id FROM attachment").is_empty())
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}

///|
async test "general attachment migration preserves image metadata and references" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    attachment_upgrade_fixture(pool, 22)
    let linked = "".pad_start(64, 'a')
    let pending = "".pad_start(64, 'b')
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user"(id,name_key,display_name,password_hash) VALUES(1,'alice','Alice','hash');
          #|INSERT INTO team(id,name_key,display_name,kind) VALUES(1,'alice','Alice','personal');
          #|INSERT INTO repository(id,team_id,name) VALUES(1,1,'demo');
          #|INSERT INTO issue(id,repository_id,number,author_id,title) VALUES(1,1,1,1,'Images');
          #|PRAGMA user_version=22;
        ),
      )
      for (id, claimed) in [(linked, 1L), (pending, 0L)] {
        ignore(
          client.execute(
            "INSERT INTO attachment(id,repository_id,uploader_id,filename,media_type,byte_size,sha256,ready,claimed) VALUES(?,1,1,'image.png','image/png',42,'digest',1,?)",
            params=[id, claimed],
          ),
        )
      }
      ignore(
        client.execute(
          "INSERT INTO attachment_reference(attachment_id,issue_id) VALUES(?,1)",
          params=[linked],
        ),
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      assert_eq(client.query_all("SELECT id FROM attachment").length(), 2)
      let row = client.query_one(
        "SELECT filename,byte_size,claimed FROM attachment WHERE id=?",
        params=[linked],
      )
      assert_eq((row.get_name("filename") : String), "image.png")
      assert_eq((row.get_name("byte_size") : Int64), 42L)
      assert_eq((row.get_name("claimed") : Int64), 1L)
      assert_eq(
        (
          client
          .query_one(
            "SELECT attachment_id FROM attachment_reference WHERE issue_id=1",
          )
          .get_name("attachment_id") : String),
        linked,
      )
      assert_eq(
        (
          client
          .query_one("SELECT claimed FROM attachment WHERE id=?", params=[
            pending,
          ])
          .get_name("claimed") : Int64),
        0L,
      )
      ignore(
        client.execute(
          "INSERT INTO attachment(id,repository_id,uploader_id,filename,media_type,byte_size,sha256) VALUES(?,1,1,'archive.zip','application/octet-stream',26214400,'digest')",
          params=["".pad_start(64, 'c')],
        ),
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
      ignore(client.execute("DELETE FROM issue WHERE id=1"))
      assert_true(
        client.query_all("SELECT * FROM attachment_reference").is_empty(),
      )
      assert_eq(client.query_all("SELECT id FROM attachment").length(), 3)
    })
  })
}

///|
async fn attachment_upgrade_fixture(pool : Database, version : Int32) -> Unit {
  for
    index, file in [
      "db/base.sql", "db/migrations/001_ssh_keys.sql", "db/migrations/002_repository_jobs.sql",
      "db/migrations/003_ssh_addresses.sql", "db/migrations/004_merge_requests.sql",
      "db/migrations/005_mail_settings.sql", "db/migrations/006_personal_namespaces.sql",
      "db/migrations/007_pipelines.sql", "db/migrations/008_pipeline_protocol.sql",
      "db/migrations/009_runner_steps.sql", "db/migrations/010_password_resets.sql",
      "db/migrations/011_provider_scope.sql", "db/migrations/012_pipeline_push.sql",
      "db/migrations/013_repository_deploy_keys.sql", "db/migrations/014_merge_checks.sql",
      "db/migrations/015_notifications.sql", "db/migrations/016_access_tokens.sql",
      "db/migrations/017_pull_request_workflows.sql", "db/migrations/018_run_context.sql",
      "db/migrations/019_merge_discussions.sql", "db/migrations/020_discussion_notification_targets.sql",
      "db/migrations/021_merge_discussion_anchors.sql", "db/migrations/022_attachments.sql",
    ] {
    if index <= version {
      let sql = @fs.read_file(file).text()
      pool.with_client(client => client.batch_execute(sql))
    }
  }
}
