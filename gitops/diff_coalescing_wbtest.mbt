///|
fn assert_diff_executor_idle(
  executor : DiffExecutor,
  concurrency~ : Int32 = 1,
) -> Unit raise {
  assert_eq(executor.waiting, 0)
  assert_eq(executor.inflight.length(), 0)
  for _ in 0..<concurrency {
    assert_true(executor.slots.try_acquire())
  }
  assert_true(!executor.slots.try_acquire())
  for _ in 0..<concurrency {
    executor.slots.release()
  }
}

///|
async test "overlapping same keys share one result with disabled oversized and enabled caches" {
  for concurrency in [1, 3] {
    for limit in [0L, 324L, 600L] {
      let joined = @async.Semaphore(2, initial_value=0)
      let entered = @async.Semaphore(1, initial_value=0)
      let finish = @async.Semaphore(1, initial_value=0)
      let events : Array[Json] = []
      let executor = DiffExecutor::new(concurrency~, cache_limit_bytes=limit, observe=event => {
        events.push(event)
        if event is { "coalesced": true, .. } {
          joined.release()
        }
      })
      let mut loads = 0
      @async.with_task_group(group => {
        let first = group.spawn(() => {
          executor.compute_cached("a", "file", () => {
            loads += 1
            entered.release()
            finish.acquire()
            Document("xx")
          })
        })
        entered.acquire()
        let others = [
          for _ in 0..<2 => {
            group.spawn(() => {
              executor.compute_cached("a", "file", () => {
                fail("shared loader ran")
              })
            })
          }
        ]
        joined.acquire()
        joined.acquire()
        assert_eq(executor.waiting, 2)
        assert_eq(executor.inflight.length(), 1)
        finish.release()
        assert_true(first.wait() is Document("xx"))
        for other in others {
          assert_true(other.wait() is Document("xx"))
        }
      })
      assert_eq(loads, 1)
      assert_eq(executor.completed, 1)
      assert_eq(executor.coalesced_requests, 2L)
      assert_eq(executor.cache_hits, 0)
      assert_eq(executor.cache.length(), if limit == 600L { 1 } else { 0 })
      assert_eq(executor.cache_skips, if limit == 600L { 0L } else { 1L })
      assert_eq(events.length(), 3)
      assert_true(
        events[0] is { "coalesced": true, "coalesced_requests_total": "1", .. },
      )
      assert_true(
        events[2]
        is { "termination": "success", "coalesced_requests_total": "2", .. },
      )
      assert_diff_executor_idle(executor, concurrency~)
      assert_diff_cache_budget(executor)
      // The in-flight Lazy must not act as an extra completed-result cache.
      ignore(
        executor.compute_cached("a", "file", () => {
          loads += 1
          Document("xx")
        }),
      )
      assert_eq(loads, if limit == 600L { 1 } else { 2 })
    }
  }
}

///|
async test "cancelling either original or joined caller leaves shared work running" {
  for cancel_first in [true, false] {
    let entered = @async.Semaphore(1, initial_value=0)
    let joined = @async.Semaphore(1, initial_value=0)
    let finish = @async.Semaphore(1, initial_value=0)
    let executor = DiffExecutor::new(observe=event => {
      if event is { "coalesced": true, .. } {
        joined.release()
      }
    })
    let mut cleaned = false
    @async.with_task_group(group => {
      let first = group.spawn(() => {
        executor.compute_cached("a", "file", () => {
          defer {
            cleaned = true
          }
          entered.release()
          finish.acquire()
          Document("ok")
        })
      })
      entered.acquire()
      let second = group.spawn(() => {
        executor.compute_cached("a", "file", () => fail("joined loader"))
      })
      joined.acquire()
      let (cancelled, survivor) = if cancel_first {
        (first, second)
      } else {
        (second, first)
      }
      cancelled.cancel()
      ignore(cancelled.wait()) catch {
        @async.WaitedTaskAlreadyCancelled => ()
        err => raise err
      }
      assert_true(!cleaned)
      assert_eq(executor.inflight.length(), 1)
      assert_eq(executor.inflight["a"].0.waiters, 1)
      assert_eq(executor.waiting, 0)
      assert_true(!executor.slots.try_acquire())
      finish.release()
      assert_true(survivor.wait() is Document("ok"))
    })
    assert_true(cleaned)
    assert_eq(executor.completed, 1)
    assert_eq(executor.failures, 0)
    assert_diff_executor_idle(executor)
  }
}

///|
async test "last cancellation waits for cleanup while a new same key task remains registered" {
  let entered = @async.Semaphore(1, initial_value=0)
  let joined = @async.Semaphore(1, initial_value=0)
  let cleaning = @async.Semaphore(1, initial_value=0)
  let finish_cleanup = @async.Semaphore(1, initial_value=0)
  let new_entered = @async.Semaphore(1, initial_value=0)
  let finish_new = @async.Semaphore(1, initial_value=0)
  let executor = DiffExecutor::new(concurrency=2, observe=event => {
    if event is { "coalesced": true, .. } {
      joined.release()
    }
  })
  let mut cleaned = false
  @async.with_task_group(group => {
    let first = group.spawn(() => {
      executor.compute_cached("a", "file", () => {
        defer @async.protect_from_cancel(() => {
          cleaning.release()
          finish_cleanup.acquire()
          cleaned = true
        })
        entered.release()
        @async.Semaphore(1, initial_value=0).acquire()
        Document("old")
      })
    })
    entered.acquire()
    let second = group.spawn(() => {
      executor.compute_cached("a", "file", () => fail("joined loader"))
    })
    joined.acquire()
    first.cancel()
    ignore(first.wait()) catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
    second.cancel()
    cleaning.acquire()
    assert_true(second.try_wait() is None)
    assert_eq(executor.inflight.length(), 0)
    let newer = group.spawn(() => {
      executor.compute_cached("a", "file", () => {
        new_entered.release()
        finish_new.acquire()
        Document("new")
      })
    })
    new_entered.acquire()
    let new_id = executor.inflight["a"].0.id
    finish_cleanup.release()
    ignore(second.wait()) catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
    assert_true(cleaned)
    assert_eq(executor.inflight["a"].0.id, new_id)
    assert_true(!executor.cache.contains("a"))
    finish_new.release()
    assert_true(newer.wait() is Document("new"))
  })
  assert_eq(executor.completed, 1)
  assert_diff_executor_idle(executor, concurrency=2)
}

///|
async test "independent keys execute concurrently and shared waiters use the bounded queue" {
  let entered = @async.Semaphore(2, initial_value=0)
  let joined = @async.Semaphore(16, initial_value=0)
  let finish = @async.Semaphore(2, initial_value=0)
  let executor = DiffExecutor::new(concurrency=2, observe=event => {
    if event is { "coalesced": true, .. } {
      joined.release()
    }
  })
  @async.with_task_group(group => {
    let active = [
      for key in ["a", "b"] => {
        group.spawn(() => {
          executor.compute_cached(key, "file", () => {
            entered.release()
            finish.acquire()
            Document(key)
          })
        })
      }
    ]
    entered.acquire()
    entered.acquire()
    let duplicates = [
      for _ in 0..<15 => {
        group.spawn(() => {
          executor.compute_cached("a", "file", () => fail("joined loader"))
        })
      }
    ]
    for _ in 0..<15 {
      joined.acquire()
    }
    // An independent queued job takes the sixteenth position without loading.
    let queued_started = @async.Semaphore(1, initial_value=0)
    let queued = group.spawn(() => {
      queued_started.release()
      executor.compute_cached("c", "file", () => Document("c"))
    })
    queued_started.acquire()
    assert_eq(executor.waiting, 16)
    for key in ["a", "d"] {
      try
        ignore(
          executor.compute_cached(key, "file", () => fail("overflow loader")),
        )
      catch {
        DiffFailure(reason) => assert_true(reason.contains("queue is full"))
        err => raise err
      } noraise {
        _ => fail("accepted overflow")
      }
    }
    queued.cancel()
    ignore(queued.wait()) catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
    assert_eq(executor.waiting, 15)
    let replacement = group.spawn(() => {
      executor.compute_cached("b", "file", () => fail("joined loader"))
    })
    joined.acquire()
    assert_eq(executor.waiting, 16)
    finish.release()
    finish.release()
    assert_true(active[0].wait() is Document("a"))
    assert_true(active[1].wait() is Document("b"))
    assert_true(replacement.wait() is Document("b"))
    for task in duplicates {
      assert_true(task.wait() is Document("a"))
    }
  })
  assert_eq(executor.completed, 2)
  assert_diff_executor_idle(executor, concurrency=2)
}

///|
async test "queued shared task survives its original caller cancellation and cancels before loading" {
  let joined = @async.Semaphore(1, initial_value=0)
  let queued = @async.Semaphore(1, initial_value=0)
  let executor = DiffExecutor::new(observe=event => {
    if event is { "coalesced": true, .. } {
      joined.release()
    }
  })
  executor.slots.acquire()
  @async.with_task_group(group => {
    let first = group.spawn(() => {
      queued.release()
      executor.compute_cached("a", "file", () => fail("queued loader"))
    })
    queued.acquire()
    let second = group.spawn(() => {
      executor.compute_cached("a", "file", () => fail("joined loader"))
    })
    joined.acquire()
    assert_eq(executor.waiting, 2)
    first.cancel()
    ignore(first.wait()) catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
    assert_eq(executor.waiting, 1)
    second.cancel()
    ignore(second.wait()) catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
    assert_eq(executor.waiting, 0)
    assert_eq(executor.inflight.length(), 0)
  })
  executor.slots.release()
  assert_eq(executor.completed, 0)
  assert_diff_executor_idle(executor)
}

///|
async test "queued cancellation during permit handoff restores executor capacity" {
  let entered = @async.Semaphore(1, initial_value=0)
  let queued = @async.Semaphore(1, initial_value=0)
  let finish = @async.Semaphore(1, initial_value=0)
  let executor = DiffExecutor::new(cache_limit_bytes=0L)
  @async.with_task_group(group => {
    let first = group.spawn(() => {
      executor.compute_cached("a", "file", () => {
        entered.release()
        finish.acquire()
        Document("first")
      })
    })
    entered.acquire()
    let second = group.spawn(() => {
      queued.release()
      executor.compute_cached("b", "file", () => fail("cancelled loader"))
    })
    queued.acquire()
    @async.sleep(0)
    assert_eq(executor.waiting, 1)
    finish.release()
    second.cancel()
    assert_true(first.wait() is Document("first"))
    ignore(second.wait()) catch {
      @async.WaitedTaskAlreadyCancelled => ()
      err => raise err
    }
  })
  assert_eq(executor.completed, 1)
  assert_diff_executor_idle(executor)
  let mut loaded = false
  assert_true(
    executor.compute_cached("b", "file", () => {
      loaded = true
      Document("retry")
    })
    is Document("retry"),
  )
  assert_true(loaded)
  assert_eq(executor.completed, 2)
  assert_eq(executor.cache_hits, 0)
  assert_diff_executor_idle(executor)
}

///|
async test "queue timeout during permit handoff restores executor capacity" {
  let queued = @async.Semaphore(1, initial_value=0)
  let executor = DiffExecutor::new(cache_limit_bytes=0L)
  executor.slots.acquire()
  @async.with_task_group(group => {
    let task = group.spawn(allow_failure=true, () => {
      queued.release()
      executor.compute_cached("a", "file", () => fail("expired loader"))
    })
    queued.acquire()
    @async.sleep(@diff_protocol.queue_wait_ms)
    executor.slots.release()
    try ignore(task.wait()) catch {
      DiffFailure(reason) =>
        assert_eq(reason, "diff queue wait exceeded; retry shortly")
      err => raise err
    } noraise {
      _ => fail("queue did not time out")
    }
  })
  assert_eq(executor.completed, 0)
  assert_diff_executor_idle(executor)
  let mut loaded = false
  assert_true(
    executor.compute_cached("a", "file", () => {
      loaded = true
      Document("retry")
    })
    is Document("retry"),
  )
  assert_true(loaded)
  assert_eq(executor.completed, 1)
  assert_eq(executor.cache_hits, 0)
  assert_diff_executor_idle(executor)
}

///|
async test "shared execution timeout and failure propagate once and allow retry" {
  for timeout in [true, false] {
    let entered = @async.Semaphore(1, initial_value=0)
    let joined = @async.Semaphore(1, initial_value=0)
    let fail_now = @async.Semaphore(1, initial_value=0)
    let executor = DiffExecutor::new(deadline_ms=1000, observe=event => {
      if event is { "coalesced": true, .. } {
        joined.release()
      }
    })
    let mut loads = 0
    let mut cleaned = false
    @async.with_task_group(group => {
      let first = group.spawn(allow_failure=true, () => {
        executor.compute_cached("a", "manifest", () => {
          defer {
            cleaned = true
          }
          loads += 1
          entered.release()
          fail_now.acquire()
          raise DiffFailure("worker failed")
        })
      })
      entered.acquire()
      let second = group.spawn(allow_failure=true, () => {
        executor.compute_cached("a", "manifest", () => fail("joined loader"))
      })
      joined.acquire()
      if !timeout {
        fail_now.release()
      }
      for task in [first, second] {
        try ignore(task.wait()) catch {
          DiffFailure(reason) =>
            assert_eq(
              reason,
              if timeout {
                "diff manifest timed out; retry shortly"
              } else {
                "worker failed"
              },
            )
          err => raise err
        } noraise {
          _ => fail("shared work succeeded")
        }
      }
    })
    assert_eq(loads, 1)
    assert_true(cleaned)
    assert_eq(executor.failures, 1)
    assert_eq(executor.completed, 0)
    assert_eq(executor.cache.length(), 0)
    assert_diff_executor_idle(executor)
    assert_true(
      executor.compute_cached("a", "manifest", () => Manifest([]))
      is Manifest([]),
    )
    assert_eq(executor.completed, 1)
  }
}

///|
async test "shared worker success and protocol failure account for one subprocess" {
  for valid in [true, false] {
    let entered = @async.Semaphore(1, initial_value=0)
    let joined = @async.Semaphore(1, initial_value=0)
    let finish = @async.Semaphore(1, initial_value=0)
    let executor = DiffExecutor::new(
      worker="_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe",
      concurrency=2,
      cache_limit_bytes=0L,
      observe=event => {
        if event is { "coalesced": true, .. } {
          joined.release()
        }
      },
    )
    let request = diff_test_request()
    let request = if valid {
      request
    } else {
      { ..request, protocol: "unsupported", }
    }
    let mut loads = 0
    @async.with_task_group(group => {
      let first = group.spawn(allow_failure=true, () => {
        executor.execute("worker", () => {
          loads += 1
          entered.release()
          finish.acquire()
          request
        })
      })
      entered.acquire()
      let second = group.spawn(allow_failure=true, () => {
        executor.execute("worker", () => fail("joined loader"))
      })
      joined.acquire()
      finish.release()
      for task in [first, second] {
        if valid {
          assert_eq(task.wait().status, "changed")
        } else {
          try ignore(task.wait()) catch {
            DiffFailure(reason) =>
              assert_eq(reason, "unsupported diff protocol")
            err => raise err
          } noraise {
            _ => fail("accepted bad protocol")
          }
        }
      }
    })
    assert_eq(loads, 1)
    assert_eq(
      executor.input_bytes,
      @utf8.encode(Json(request).stringify()).length().to_int64(),
    )
    assert_true(executor.output_bytes > 0L)
    assert_eq(executor.completed, if valid { 1 } else { 0 })
    assert_eq(executor.failures, if valid { 0 } else { 1 })
    assert_eq(executor.cache_hits, 0)
    assert_eq(executor.cache.length(), 0)
    assert_diff_executor_idle(executor, concurrency=2)
    if !valid {
      assert_eq(
        executor.execute("worker", () => diff_test_request()).status,
        "changed",
      )
    }
  }
}

///|
async test "last shared worker cancellation waits for process reaping and permit return" {
  if @async.platform is Windows {
    return
  }
  @test_support.with_git_test_repo((root, _) => {
    let script = "\{root}/shared-cpu-worker"
    let pid_file = "\{root}/shared-pid"
    @fs.write_file(
      script,
      "#!/bin/sh\necho $$ > '\{pid_file}'\nwhile :; do :; done\n",
    )
    @fs.chmod(script, 0o700)
    for cancel_first in [true, false] {
      let joined = @async.Semaphore(1, initial_value=0)
      let executor = DiffExecutor::new(worker=script, observe=event => {
        if event is { "coalesced": true, .. } {
          joined.release()
        }
      })
      @async.with_task_group(group => {
        let first = group.spawn(() => {
          executor.execute("cpu", () => diff_test_request())
        })
        let pid = @async.with_timeout(2000, () => {
          while !@fs.exists(pid_file) {
            @async.sleep(0)
          }
          let mut pid = ""
          while pid.is_empty() {
            pid = @fs.read_file(pid_file).text().trim().to_owned()
            if pid.is_empty() {
              @async.sleep(0)
            }
          }
          pid
        })
        let second = group.spawn(() => {
          executor.execute("cpu", () => fail("joined loader"))
        })
        joined.acquire()
        let (cancelled, last) = if cancel_first {
          (first, second)
        } else {
          (second, first)
        }
        cancelled.cancel()
        ignore(cancelled.wait()) catch {
          @async.WaitedTaskAlreadyCancelled => ()
          err => raise err
        }
        let (code, _, _) = @process.collect_output("kill", ["-0", pid])
        assert_eq(code, 0)
        assert_true(!executor.slots.try_acquire())
        last.cancel()
        ignore(last.wait()) catch {
          @async.WaitedTaskAlreadyCancelled => ()
          err => raise err
        }
        let (code, _, _) = @process.collect_output("kill", ["-0", pid])
        assert_true(code != 0)
      })
      @fs.remove(pid_file)
      assert_eq(executor.completed, 0)
      assert_eq(executor.cache.length(), 0)
      assert_eq(executor.last_termination, "cancelled")
      assert_diff_executor_idle(executor)
    }
  })
}

///|
async test "queued shared callers receive the original admission timeout and can retry" {
  let queued = @async.Semaphore(1, initial_value=0)
  let joined = @async.Semaphore(1, initial_value=0)
  let executor = DiffExecutor::new(observe=event => {
    if event is { "coalesced": true, .. } {
      joined.release()
    }
  })
  executor.slots.acquire()
  @async.with_task_group(group => {
    let first = group.spawn(allow_failure=true, () => {
      queued.release()
      executor.compute_cached("a", "manifest", () => fail("expired loader"))
    })
    queued.acquire()
    let second = group.spawn(allow_failure=true, () => {
      executor.compute_cached("a", "manifest", () => fail("joined loader"))
    })
    joined.acquire()
    assert_eq(executor.inflight.length(), 1)
    assert_eq(executor.coalesced_requests, 1L)
    for task in [first, second] {
      try ignore(task.wait()) catch {
        DiffFailure(reason) =>
          assert_eq(reason, "diff queue wait exceeded; retry shortly")
        err => raise err
      } noraise {
        _ => fail("queue did not time out")
      }
    }
  })
  executor.slots.release()
  assert_eq(executor.completed, 0)
  assert_eq(executor.cache.length(), 0)
  assert_diff_executor_idle(executor)
  assert_true(
    executor.compute_cached("a", "manifest", () => Manifest([])) is Manifest([]),
  )
  assert_eq(executor.completed, 1)
}
