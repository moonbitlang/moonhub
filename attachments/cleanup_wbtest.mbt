///|
async test "repository deletion journals attachments and retries partial cleanup under the upload lock" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let scope = @repository.repository_scope(pool, actor, repo)
    let file = upload(pool, root, scope, actor, "test.txt", b"attachment")
    let path = storage_path(root, file.id)
    @fs.write_file(path + ".tmp", "partial upload")
    @repository.delete_repository(
      pool,
      root,
      actor,
      repo,
      scope.id,
      repo.path(),
    )
    pool.with_client(client => {
      assert_true(client.query_all("SELECT * FROM attachment").is_empty())
      assert_eq(
        client.query_all("SELECT * FROM attachment_file_garbage").length(),
        1,
      )
    })
    let uploader = attachment_storage_lock(root)
    assert_true(uploader.try_lock(Exclusive))
    cleanup_pending(pool, root)
    assert_true(@fs.exists(path))
    uploader.close()
    // The first file disappeared before a restart; the temporary file is unsafe.
    @fs.remove(path)
    @fs.remove(path + ".tmp")
    @fs.mkdir(path + ".tmp")
    cleanup_pending(pool, root)
    pool.with_client(client => {
      let row = client.query_one(
        "SELECT attempts,last_error FROM attachment_file_garbage",
      )
      assert_eq((row.get_name("attempts") : Int64), 1L)
      assert_false((row.get_name("last_error") : String).is_empty())
      ignore(
        client.execute(
          "UPDATE attachment_file_garbage SET next_attempt_at=datetime('now')",
        ),
      )
    })
    @fs.rmdir(path + ".tmp")
    cleanup_pending(pool, root)
    cleanup_pending(pool, root)
    pool.with_client(client => {
      assert_true(
        client.query_all("SELECT * FROM attachment_file_garbage").is_empty(),
      )
    })
  })
}

///|
async test "attachment cleanup survives restart and refuses traversal and storage symlinks" {
  @test_support.with_git_test_repo((root, _) => {
    @async.with_task_group(group => {
      let path = "\{root}/attachments.db"
      let pool = @database.new_db_pool({ path, }, group)
      @database.initialize_db(pool)
      let id = "a".repeat(64)
      let lock = attachment_storage_lock(root)
      lock.close()
      @fs.write_file(storage_path(root, id), "persisted")
      pool.with_client(client => {
        ignore(
          client.execute(
            "INSERT INTO attachment_file_garbage(id) VALUES(?),('../outside')",
            params=[id],
          ),
        )
      })
      pool.close()
      let reopened = @database.new_db_pool({ path, }, group)
      defer reopened.close()
      @database.initialize_db(reopened)
      cleanup_pending(reopened, root)
      assert_false(@fs.exists(storage_path(root, id)))
      reopened.with_client(client => {
        let rows = client.query_all(
          "SELECT id,attempts FROM attachment_file_garbage",
        )
        assert_eq(rows.length(), 1)
        assert_eq((rows[0].get_name("id") : String), "../outside")
        assert_eq((rows[0].get_name("attempts") : Int64), 1L)
      })
      @fs.rename("\{root}/.attachments", "\{root}/safe")
      @fs.symlink(target="\{root}/safe", "\{root}/.attachments")
      try cleanup_pending(reopened, root) catch {
        @domain.BadRequest(_) => ()
        err => raise err
      } noraise {
        _ => fail("followed attachment storage symlink")
      }
    })
  })
}
