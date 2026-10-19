///|
async test "image attachment migration preserves collaboration and reinitializes safely" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user"(id,name_key,display_name,password_hash) VALUES(1,'alice','Alice','hash');
          #|INSERT INTO team(id,name_key,display_name,kind) VALUES(1,'alice','Alice','personal');
          #|INSERT INTO repository(id,team_id,name) VALUES(1,1,'demo');
          #|INSERT INTO issue(id,repository_id,number,author_id,title,description) VALUES(1,1,1,1,'Existing','Keep this');
          #|DROP TABLE attachment_reference;
          #|DROP TABLE attachment;
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
