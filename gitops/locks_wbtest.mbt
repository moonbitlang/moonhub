///|
async test "nonblocking locks share safe opens and close contended handles" {
  @test_support.with_git_test_repo((root, _) => {
    let path = "\{root}/control.lock"
    let first = file_lock(path, mode=Shared)
    defer first.close()
    let second = try_file_lock(path, mode=Shared).unwrap()
    defer second.close()
    for _ in 0..<100 {
      assert_true(try_file_lock(path) is None)
    }
    first.close()
    assert_true(try_file_lock(path) is None)
    second.close()
    let writer = try_file_lock(path).unwrap()
    defer writer.close()
    assert_true(try_file_lock(path, mode=Shared) is None)
    writer.close()
    let next = file_lock(path)
    next.close()
    for invalid in ["\{root}/directory", "\{root}/symlink", "\{root}/dangling"] {
      if invalid.has_suffix("directory") {
        @fs.mkdir(invalid)
      } else {
        @fs.symlink(
          target=if invalid.has_suffix("dangling") {
            "\{root}/missing"
          } else {
            path
          },
          invalid,
        )
      }
      for blocking in [true, false] {
        try {
          if blocking {
            let lock = file_lock(invalid)
            lock.close()
          } else if try_file_lock(invalid) is Some(lock) {
            lock.close()
          }
        } catch {
          Failure(_) => ()
          err => raise err
        } noraise {
          _ => fail("unsafe lock path accepted")
        }
      }
    }
    try ignore(try_file_lock("\{root}/missing/lock")) catch {
      @os_error.OSError(_) => ()
      err => raise err
    } noraise {
      _ => fail("open failure was reported as contention")
    }
  })
}
