///|
async test "shared repository reads overlap and exclude writers until every reader closes" {
  @test_support.with_repository_test_data((_, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let first = repository_read_lock(root, repo)
    defer first.close()
    let second = repository_read_lock(root, repo)
    defer second.close()
    let path = control_lock_path(
      root,
      "repositories",
      @identity.hash_token(repo.path()),
    )
    let writer = @fs.open(path, mode=ReadWrite)
    defer writer.close()
    assert_false(writer.try_lock(Exclusive))
    first.close()
    assert_false(writer.try_lock(Exclusive))
    second.close()
    assert_true(writer.try_lock(Exclusive))
    writer.unlock()
    let current = repository_write_lock(root, repo)
    defer current.close()
    assert_false(writer.try_lock(Shared))
  })
}

///|
async test "cancelling a read holder or queued read releases its control handle" {
  @test_support.with_repository_test_data((_, root) => {
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let started = @async.Semaphore(1, initial_value=0)
    @async.with_task_group(group => {
      let reader = group.spawn(() => {
        let lock = repository_read_lock(root, repo)
        defer lock.close()
        started.release()
        @async.CondVar::Cond().wait()
      })
      started.acquire()
      reader.cancel()
      try reader.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        err => raise err
      } noraise {
        _ => fail("read holder was not cancelled")
      }
      let writer = repository_write_lock(root, repo)
      defer writer.close()
      let queued : @async.Task[Unit] = group.spawn(() => {
        started.release()
        let lock = repository_read_lock(root, repo)
        defer lock.close()
        fail("cancelled reader acquired the writer's lock")
      })
      started.acquire()
      queued.cancel()
      try queued.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        err => raise err
      } noraise {
        _ => fail("queued read was not cancelled")
      }
      writer.close()
      let next = repository_write_lock(root, repo)
      defer next.close()
    })
  })
}
