///|
fn assert_diff_cache_budget(executor : DiffExecutor) -> Unit raise {
  let mut expected = executor.cache_index_bytes()
  for _, (_, size) in executor.cache {
    expected += size
  }
  assert_eq(executor.cache_bytes, expected)
  assert_true(expected >= 0L && expected <= executor.cache_limit_bytes)
  assert_true(
    executor.cache.capacity().to_int64() <=
    (4L * executor.cache.length().to_int64()).max(8L),
  )
}

///|
async test "capacity cache retains more than 64 small values and repeated hits do not grow the index" {
  let executor = DiffExecutor::new()
  assert_eq(executor.cache_limit_bytes, 33554432L)
  for i in 0..<256 {
    ignore(executor.compute_cached(i.to_string(), "file", () => Document("x")))
    assert_diff_cache_budget(executor)
  }
  let capacity = executor.cache.capacity()
  let bytes = executor.cache_bytes
  for _ in 0..<4 {
    for i in 0..<256 {
      assert_true(
        executor.compute_cached(i.to_string(), "file", () => fail("miss"))
        is Document("x"),
      )
      assert_diff_cache_budget(executor)
    }
  }
  assert_eq(executor.cache.length(), 256)
  assert_eq(executor.cache.capacity(), capacity)
  assert_eq(executor.cache_bytes, bytes)
  assert_eq(executor.completed, 256)
  assert_eq(executor.cache_hits, 1024)
  assert_eq(executor.cache_evictions, 0L)
}

///|
async test "exact budget includes key value entry and minimum index overhead" {
  // One-character key and value: 128 + 34 + 34 + (64 + 8 * 8) = 324.
  for limit in [323L, 324L, 325L] {
    let executor = DiffExecutor::new(cache_limit_bytes=limit)
    assert_true(
      executor.compute_cached("a", "file", () => Document("x")) is Document("x"),
    )
    assert_eq(executor.cache.length(), if limit < 324 { 0 } else { 1 })
    assert_eq(executor.cache_bytes, if limit < 324 { 0L } else { 324L })
    assert_diff_cache_budget(executor)
  }
}

///|
async test "hits refresh LRU and manifests and documents share one byte budget" {
  // Empty manifest costs 64, one-character document 34. Entry/key costs 162.
  let executor = DiffExecutor::new(cache_limit_bytes=550L)
  ignore(executor.compute_cached("m", "manifest", () => Manifest([])))
  ignore(executor.compute_cached("a", "file", () => Document("x")))
  assert_eq(executor.cache_bytes, 550L)
  assert_true(executor.cached("m", "manifest") is Some(Manifest([])))
  ignore(executor.compute_cached("b", "file", () => Document("x")))
  assert_eq(executor.cache.keys().collect(), ["m", "b"])
  assert_eq(executor.cache_evictions, 1L)
  assert_diff_cache_budget(executor)
  ignore(executor.compute_cached("n", "manifest", () => Manifest([])))
  assert_eq(executor.cache.keys().collect(), ["b", "n"])
  assert_eq(executor.cache_evictions, 2L)
  assert_diff_cache_budget(executor)
}

///|
async test "replacement accounting and oversize rejection preserve the previous value and order" {
  let executor = DiffExecutor::new(cache_limit_bytes=600L)
  ignore(executor.compute_cached("a", "file", () => Document("x")))
  ignore(executor.compute_cached("b", "file", () => Document("x")))
  assert_eq(executor.cache_bytes, 520L)
  let larger = Document("1234567890")
  executor.cache_result("a", larger, larger.retained_bytes())
  assert_eq(executor.cache_bytes, 538L)
  assert_eq(executor.cache.keys().collect(), ["b", "a"])
  assert_diff_cache_budget(executor)
  let smaller = Document("")
  executor.cache_result("a", smaller, smaller.retained_bytes())
  assert_eq(executor.cache_bytes, 518L)
  assert_diff_cache_budget(executor)
  let oversized = Document("x".repeat(300))
  for key in ["a", "c", "long".repeat(300)] {
    executor.cache_result(key, oversized, oversized.retained_bytes())
    assert_eq(executor.cache.keys().collect(), ["b", "a"])
    assert_eq(executor.cache_bytes, 518L)
    assert_diff_cache_budget(executor)
  }
  // The key alone can make a tiny value uncacheable.
  executor.cache_result("k".repeat(300), smaller, smaller.retained_bytes())
  assert_eq(executor.cache_skips, 4L)
  assert_eq(executor.cache_evictions, 0L)
  assert_true(executor.cached("a", "file") is Some(Document("")))
  assert_eq(executor.cache.length(), 2)
}

///|
async test "zero budget returns successful results on every request without caching" {
  let executor = DiffExecutor::new(cache_limit_bytes=0L)
  for _ in 0..<3 {
    assert_true(
      executor.compute_cached("a", "file", () => Document("x")) is Document("x"),
    )
    assert_true(
      executor.compute_cached("m", "manifest", () => Manifest([]))
      is Manifest([]),
    )
    assert_diff_cache_budget(executor)
  }
  assert_eq(executor.cache.length(), 0)
  assert_eq(executor.cache_bytes, 0L)
  assert_eq(executor.cache.capacity(), 8)
  assert_eq(executor.completed, 6)
  assert_eq(executor.cache_hits, 0)
  assert_eq(executor.cache_skips, 6L)
  try ignore(DiffExecutor::new(cache_limit_bytes=-1L)) catch {
    DiffFailure(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted negative budget")
  }
  let large = DiffExecutor::new(cache_limit_bytes=9223372036854775807L)
  ignore(large.compute_cached("a", "file", () => Document("x")))
  assert_eq(large.cache_bytes, 324L)
}

///|
async test "UTF16 strings and manifest allocated capacity are counted without JSON serialization" {
  assert_eq(diff_string_bytes(""), 32L)
  assert_eq(diff_string_bytes("a中😀"), 40L)
  assert_eq(Document("a中😀").retained_bytes(), 40L)
  let file : DiffFile = {
    id: "i",
    status: "M",
    old_path: "中😀",
    new_path: "a",
    old_mode: "100644",
    new_mode: "100755",
    old_blob: "a".repeat(40),
    new_blob: "b".repeat(40),
    path_error: Some("错误😀"),
  }
  let files : Array[DiffFile] = Array(capacity=32)
  files.push(file)
  // Eight strings: 256 + 2 * 98. Optional error: 32 + 2 * 4.
  assert_eq(Manifest(files).retained_bytes(), 64L + 256L + 128L + 452L + 40L)
  let compact = [file]
  assert_eq(
    Manifest(files).retained_bytes() - Manifest(compact).retained_bytes(),
    8L * (files.capacity() - compact.capacity()).to_int64(),
  )
  files[0] = { ..file, path_error: None, }
  assert_eq(Manifest(files).retained_bytes(), 64L + 256L + 128L + 452L)
}

///|
async test "actual bucket growth is charged and may cause capacity eviction" {
  // Seven tiny entries fit only if one incorrectly assumes an eight-bucket map.
  let executor = DiffExecutor::new(cache_limit_bytes=1486L)
  for i in 0..<7 {
    ignore(executor.compute_cached(i.to_string(), "file", () => Document("")))
    assert_diff_cache_budget(executor)
  }
  assert_eq(executor.cache.capacity(), 16)
  assert_eq(executor.cache.length(), 6)
  assert_eq(executor.cache_bytes, 1356L)
  assert_eq(executor.cache_evictions, 1L)
  assert_true(!executor.cache.contains("0"))
}

///|
async test "one large insertion evicts multiple entries and compaction preserves LRU order" {
  let executor = DiffExecutor::new(cache_limit_bytes=100000L)
  for i in 0..<256 {
    ignore(executor.compute_cached("k\{i}", "file", () => Document("x")))
    assert_diff_cache_budget(executor)
  }
  let capacity = executor.cache.capacity()
  ignore(executor.cached("k0", "file"))
  let order = executor.cache.keys().collect()
  ignore(
    executor.compute_cached("large", "file", () => Document("x".repeat(49000))),
  )
  assert_true(executor.cache_evictions > 1L)
  assert_true(executor.cache.capacity() < capacity)
  assert_true(executor.cache.contains("large"))
  let remaining = executor.cache.length() - 1
  let expected = order[order.length() - remaining:].to_owned()
  expected.push("large")
  assert_eq(executor.cache.keys().collect(), expected)
  assert_diff_cache_budget(executor)
  let larger = Document("x".repeat(49800))
  executor.cache_result("large", larger, larger.retained_bytes())
  assert_eq(executor.cache.keys().collect(), ["large"])
  assert_eq(executor.cache.capacity(), 8)
  assert_eq(executor.cache_bytes, 99930L)
  assert_diff_cache_budget(executor)
  executor.cache.clear()
  executor.shrink_cache()
  assert_eq(executor.cache_bytes, 0L)
  assert_eq(executor.cache.capacity(), 8)
}

///|
async test "manifest memory accounting yields and remains inside the execution deadline" {
  let file : DiffFile = {
    id: "i",
    status: "M",
    old_path: "a",
    new_path: "b",
    old_mode: "100644",
    new_mode: "100644",
    old_blob: "",
    new_blob: "",
    path_error: None,
  }
  let files = Array::make(100000, file)
  let executor = DiffExecutor::new(deadline_ms=1)
  try
    ignore(executor.compute_cached("m", "manifest", () => Manifest(files)))
  catch {
    DiffFailure(reason) => assert_true(reason.contains("manifest timed out"))
    err => raise err
  } noraise {
    _ => fail("manifest accounting blocked the deadline")
  }
  assert_eq(executor.cache.length(), 0)
  assert_eq(executor.cache_bytes, 0L)
  assert_true(executor.slots.try_acquire())
  executor.slots.release()
}

///|
async test "diff logs report cache budget usage hits evictions and skips" {
  let events : Array[Json] = []
  let executor = DiffExecutor::new(cache_limit_bytes=324L, observe=event => {
    events.push(event)
  })
  ignore(executor.compute_cached("a", "file", () => Document("x")))
  ignore(executor.compute_cached("a", "file", () => fail("miss")))
  ignore(executor.compute_cached("b", "file", () => Document("x")))
  ignore(executor.compute_cached("c", "file", () => Document("xx")))
  assert_eq(events.length(), 4)
  assert_true(events[1] is { "cache": "hit", "cache_hits_total": 1, .. })
  assert_true(
    events[3]
    is {
      "cache_entries": 1,
      "cache_bytes": "324",
      "cache_limit_bytes": "324",
      "cache_evictions_total": "1",
      "cache_skips_total": "1",
      "cache_hits_total": 1,
      "termination": "success",
      ..
    },
  )
}

///|
async test "concurrent same key completions replace accounting or preserve a cached value when oversized" {
  for limit in [324L, 600L] {
    let executor = DiffExecutor::new(concurrency=2, cache_limit_bytes=limit)
    let entered = @async.Semaphore(2)
    entered.acquire()
    entered.acquire()
    let finish_first = @async.Semaphore(1)
    finish_first.acquire()
    let finish_second = @async.Semaphore(1)
    finish_second.acquire()
    @async.with_task_group(group => {
      let first = group.spawn(() => {
        executor.compute_cached("a", "file", () => {
          entered.release()
          finish_first.acquire()
          Document("x")
        })
      })
      let second = group.spawn(() => {
        executor.compute_cached("a", "file", () => {
          entered.release()
          finish_second.acquire()
          Document("xx")
        })
      })
      entered.acquire()
      entered.acquire()
      finish_first.release()
      assert_true(first.wait() is Document("x"))
      finish_second.release()
      assert_true(second.wait() is Document("xx"))
    })
    assert_eq(executor.completed, 2)
    assert_eq(executor.cache.length(), 1)
    assert_eq(executor.cache_evictions, 0L)
    if limit == 324L {
      assert_true(executor.cached("a", "file") is Some(Document("x")))
      assert_eq(executor.cache_bytes, 324L)
      assert_eq(executor.cache_skips, 1L)
    } else {
      assert_true(executor.cached("a", "file") is Some(Document("xx")))
      assert_eq(executor.cache_bytes, 326L)
      assert_eq(executor.cache_skips, 0L)
    }
    assert_diff_cache_budget(executor)
  }
}
