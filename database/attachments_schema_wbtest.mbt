///|
async test "baseline stores image and file attachments and cascades references" {
  @async.with_task_group(group => {
    let pool = new_db_pool({ path: ":memory:", }, group)
    defer pool.close()
    initialize_db(pool)
    let linked = "".pad_start(64, 'a')
    let pending = "".pad_start(64, 'b')
    pool.with_client(client => {
      client.batch_execute(
        (
          #|INSERT INTO "user"(id,name_key,display_name,password_hash) VALUES(1,'alice','Alice','hash');
          #|INSERT INTO team(id,name_key,display_name,kind) VALUES(1,'alice','Alice','personal');
          #|INSERT INTO repository(id,team_id,name) VALUES(1,1,'demo');
          #|INSERT INTO issue(id,repository_id,number,author_id,title) VALUES(1,1,1,1,'Images');
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
