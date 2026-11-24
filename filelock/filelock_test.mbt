///|
// Ownership tests deliberately retain an alias only to observe whether the
// factory closed its input; application callers must not reuse transferred files.
async fn assert_closed(file : @fs.File) -> Unit {
  try ignore(file.size()) catch {
    @os_error.OSError(_) => ()
    err => raise err
  } noraise {
    _ => fail("transferred file is still open")
  }
}

///|
async test "shared handles exclude writers and aliases close only once" {
  let root = @fs.tmpdir(prefix="moonhub-filelock-")
  defer @fs.rmdir(root, recursive=true)
  let path = "\{root}/control.lock"
  let file = @fs.open(path, mode=ReadWrite, create_mode=CreateNew)
  let first = @filelock.acquire(file, mode=Shared, timeout_ms=1000)
  defer first.close()
  let same_handle = first
  guard @filelock.try_acquire(@fs.open(path, mode=ReadWrite), mode=Shared)
    is Some(second) else {
    fail("second shared lock was unexpectedly contended")
  }
  defer second.close()
  for _ in 0..<100 {
    let contender = @fs.open(path, mode=ReadWrite)
    assert_true(@filelock.try_acquire(contender) is None)
    assert_closed(contender)
  }
  same_handle.close()
  first.close()
  assert_closed(file)
  assert_true(@filelock.try_acquire(@fs.open(path, mode=ReadWrite)) is None)
  second.close()
  guard @filelock.try_acquire(@fs.open(path, mode=ReadWrite)) is Some(writer) else {
    fail("writer remained blocked after all shared handles closed")
  }
  defer writer.close()
  // A late close of an alias must not release the next owner's lock.
  same_handle.close()
  assert_true(
    @filelock.try_acquire(@fs.open(path, mode=ReadWrite), mode=Shared) is None,
  )
}

///|
async test "timeout closes the waiter without releasing the holder" {
  let root = @fs.tmpdir(prefix="moonhub-filelock-")
  defer @fs.rmdir(root, recursive=true)
  let path = "\{root}/control.lock"
  let holder = @filelock.acquire(
    @fs.open(path, mode=ReadWrite, create_mode=CreateNew),
  )
  defer holder.close()
  for mode in [@fs.Shared, @fs.Exclusive] {
    let file = @fs.open(path, mode=ReadWrite)
    try {
      let unexpected = @filelock.acquire(file, mode~, timeout_ms=10)
      unexpected.close()
    } catch {
      @async.TimeoutError => ()
      err => raise err
    } noraise {
      _ => fail("contended acquisition did not time out")
    }
    assert_closed(file)
    assert_true(@filelock.try_acquire(@fs.open(path, mode=ReadWrite)) is None)
  }
  holder.close()
  let next = @filelock.acquire(@fs.open(path, mode=ReadWrite), timeout_ms=1000)
  next.close()
}

///|
async test "cancelled acquisitions close their files and leave the holder locked" {
  let root = @fs.tmpdir(prefix="moonhub-filelock-")
  defer @fs.rmdir(root, recursive=true)
  let path = "\{root}/control.lock"
  let holder = @filelock.acquire(
    @fs.open(path, mode=ReadWrite, create_mode=CreateNew),
  )
  defer holder.close()
  for timeout_ms in [None, Some(1000)] {
    let file = @fs.open(path, mode=ReadWrite)
    let started = @async.Semaphore(1, initial_value=0)
    @async.with_task_group(group => {
      let waiter : @async.Task[Unit] = group.spawn(() => {
        started.release()
        let unexpected = @filelock.acquire(file, timeout_ms?)
        defer unexpected.close()
        fail("cancelled waiter acquired the held lock")
      })
      started.acquire()
      waiter.cancel()
      try waiter.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        err => raise err
      } noraise {
        _ => fail("waiter did not propagate cancellation")
      }
    })
    assert_closed(file)
    assert_true(@filelock.try_acquire(@fs.open(path, mode=ReadWrite)) is None)
  }
  holder.close()
  let next = @filelock.acquire(@fs.open(path, mode=ReadWrite))
  next.close()
}

///|
async test "deferred close releases a cancelled holder or an exceptional scope" {
  let root = @fs.tmpdir(prefix="moonhub-filelock-")
  defer @fs.rmdir(root, recursive=true)
  let path = "\{root}/control.lock"
  let file = @fs.open(path, mode=ReadWrite, create_mode=CreateNew)
  let started = @async.Semaphore(1, initial_value=0)
  @async.with_task_group(group => {
    let holder = group.spawn(() => {
      let lock = @filelock.acquire(file)
      defer lock.close()
      started.release()
      @async.CondVar::Cond().wait()
    })
    started.acquire()
    assert_true(@filelock.try_acquire(@fs.open(path, mode=ReadWrite)) is None)
    holder.cancel()
    try holder.wait() catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    } noraise {
      _ => fail("holder did not propagate cancellation")
    }
  })
  assert_closed(file)
  let file = @fs.open(path, mode=ReadWrite)
  try {
    let lock = @filelock.acquire(file, timeout_ms=1000)
    defer lock.close()
    raise Failure("expected scope failure")
  } catch {
    Failure(message) => assert_eq(message, "expected scope failure")
    err => raise err
  }
  assert_closed(file)
  guard @filelock.try_acquire(@fs.open(path, mode=ReadWrite)) is Some(next) else {
    fail("exceptional scope retained its lock")
  }
  next.close()
}

///|
async test "acquisition errors propagate instead of becoming contention" {
  let root = @fs.tmpdir(prefix="moonhub-filelock-")
  defer @fs.rmdir(root, recursive=true)
  let path = "\{root}/control.lock"
  for blocking in [false, true] {
    let file = @fs.open(path, mode=ReadWrite, create_mode=OpenOrCreate)
    file.close()
    try {
      if blocking {
        let unexpected = @filelock.acquire(file, timeout_ms=1000)
        unexpected.close()
      } else if @filelock.try_acquire(file) is Some(unexpected) {
        unexpected.close()
      }
    } catch {
      @os_error.OSError(_) => ()
      err => raise err
    } noraise {
      _ => fail("invalid descriptor was accepted or reported as contention")
    }
    assert_closed(file)
  }
}
