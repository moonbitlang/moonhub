///|
async test "baseline preserves unanchored discussions and prevents moving saved anchors" {
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
          #|INSERT INTO merge_request(id,repository_id,number,author_id,title,source_branch,target_branch,current_version) VALUES(1,1,1,1,'Upgrade','source','master',1);
          #|INSERT INTO merge_activity(id,merge_request_id,actor_id,kind,body,version) VALUES(10,1,1,'comment','Root',1);
          #|INSERT INTO merge_activity(id,merge_request_id,actor_id,kind,body,version,discussion_id) VALUES(11,1,1,'comment','Reply',1,10);
          #|UPDATE merge_discussion SET resolved=1,state_version=2,state_actor_id=1 WHERE id=10;
        ),
      )
    })
    let before = pool.with_client(client => {
      client.query_all("SELECT id FROM collaboration_event").length()
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let thread = client.query_one(
        "SELECT * FROM merge_discussion WHERE id=10",
      )
      assert_eq((thread.get_name("anchor") : String?), None)
      assert_true((thread.get_name("resolved") : Bool))
      assert_eq((thread.get_name("state_version") : Int64), 2L)
      assert_eq(
        client.query_all("SELECT id FROM collaboration_event").length(),
        before,
      )
      assert_eq(
        client
        .query_all("SELECT id FROM merge_activity WHERE id IN (10,11)")
        .length(),
        2,
      )
      ignore(
        client.execute("UPDATE merge_discussion SET anchor='{}' WHERE id=10"),
      )
      for
        sql in [
          "UPDATE merge_discussion SET anchor=NULL WHERE id=10", "UPDATE merge_discussion SET anchor='{\"moved\":true}' WHERE id=10",
        ] {
        try client.execute(sql) catch {
          @moondb.QueryError(_) => ()
          err => raise err
        } noraise {
          _ => fail("saved anchor was mutable")
        }
      }
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
