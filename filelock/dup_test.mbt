///|
#cfg(not(platform="windows"))
extern "C" fn dup(fd : Int32) -> Int32 = "dup"

///|
#cfg(not(platform="windows"))
extern "C" fn close_fd(fd : Int32) -> Int32 = "close"

///|
#cfg(not(platform="windows"))
async test "close releases shared and exclusive locks while dup remains open" {
  let root = @fs.tmpdir(prefix="moonhub-filelock-dup-")
  defer @fs.rmdir(root, recursive=true)
  let path = "\{root}/control.lock"
  for blocking in [false, true] {
    for mode in [@fs.Shared, @fs.Exclusive] {
      let file = @fs.open(path, mode=ReadWrite, create_mode=OpenOrCreate)
      let duplicate = dup(file.fd())
      assert_true(duplicate >= 0, msg="dup failed")
      defer ignore(close_fd(duplicate))
      let lock = if blocking {
        @filelock.acquire(file, mode~, timeout_ms=1000)
      } else {
        guard @filelock.try_acquire(file, mode~) is Some(lock) else {
          fail("uncontended acquisition failed")
        }
        lock
      }
      defer lock.close()
      assert_true(@filelock.try_acquire(@fs.open(path, mode=ReadWrite)) is None)
      let same_handle = lock
      same_handle.close()
      // No sleep, subprocess or retry: the independent open must lock now,
      // although duplicate still holds the original open file description.
      guard @filelock.try_acquire(@fs.open(path, mode=ReadWrite)) is Some(next) else {
        fail("duplicate descriptor retained the lock after close")
      }
      defer next.close()
      lock.close()
      assert_true(@filelock.try_acquire(@fs.open(path, mode=ReadWrite)) is None)
    }
  }
}

///|
#cfg(not(platform="windows"))
async test "timeout racing with acquisition cannot leave a duplicate locked" {
  let root = @fs.tmpdir(prefix="moonhub-filelock-timeout-")
  defer @fs.rmdir(root, recursive=true)
  let path = "\{root}/control.lock"
  for _ in 0..<32 {
    let file = @fs.open(path, mode=ReadWrite, create_mode=OpenOrCreate)
    let duplicate = dup(file.fd())
    assert_true(duplicate >= 0, msg="dup failed")
    defer ignore(close_fd(duplicate))
    // Either result is valid: the lock syscall and zero-duration timer race.
    // In both cases the factory/handle must release any acquired lock.
    try {
      let lock = @filelock.acquire(file, timeout_ms=0)
      lock.close()
    } catch {
      @async.TimeoutError => ()
      err => raise err
    }
    assert_closed(file)
    guard @filelock.try_acquire(@fs.open(path, mode=ReadWrite)) is Some(next) else {
      fail("timed acquisition left its duplicate descriptor locked")
    }
    next.close()
  }
}
