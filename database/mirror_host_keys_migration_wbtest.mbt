///|
async test "mirror host key upgrade preserves mirror identities and leaves trust empty" {
  @test_support.with_ssh_test_db(pool => {
    pool.with_client(client => {
      client.batch_execute(
        "DROP TABLE mirror_host_check; ALTER TABLE repository_mirror DROP COLUMN host_keys; PRAGMA user_version=27;" +
        "INSERT INTO repository_mirror(id,repository_id,creator_id,url,active,force_push,prune,status) VALUES(1,1,1,'git@source.example:org/demo.git',0,0,0,'disabled');" +
        "INSERT INTO mirror_ssh_key(mirror_id,private_key,public_key) VALUES(1,'existing-private','existing-public');",
      )
    })
    initialize_db(pool)
    initialize_db(pool)
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT m.host_keys,k.private_key,k.public_key FROM repository_mirror m JOIN mirror_ssh_key k ON k.mirror_id=m.id WHERE m.id=1",
      )
      assert_eq((row.get_name("host_keys") : String), "")
      assert_eq((row.get_name("private_key") : String), "existing-private")
      assert_eq((row.get_name("public_key") : String), "existing-public")
      assert_eq(
        (
          client.query_one("PRAGMA user_version").get_name("user_version") :
          Int64),
        database_schema_version,
      )
      assert_true(client.query_all("PRAGMA foreign_key_check").is_empty())
    })
  })
}
