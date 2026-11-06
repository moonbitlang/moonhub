///|
async test "manifest and file stages share all sixteen wait positions without starting Git" {
  let executor = DiffExecutor::new()
  executor.slots.acquire()
  let sha = "a".repeat(40)
  @async.with_task_group(group => {
    let tasks = []
    for i in 0..<16 {
      tasks.push(
        group.spawn(() => {
          if i % 2 == 0 {
            ignore(executor.manifest("missing-repository", sha, sha))
          } else {
            ignore(
              executor.execute("queued-\{i}", () => {
                fail("source loaded before admission")
              }),
            )
          }
        }),
      )
    }
    @async.sleep(20)
    assert_eq(executor.waiting, 16)
    try ignore(executor.manifest("missing-repository", sha, sha)) catch {
      DiffFailure(reason) => assert_true(reason.contains("queue is full"))
      err => raise err
    } noraise {
      _ => fail("manifest bypassed queue")
    }
    for task in tasks {
      task.cancel()
    }
    for task in tasks {
      task.wait() catch {
        @async.WaitedTaskAlreadyCancelled => ()
        err => raise err
      }
    }
  })
  try ignore(executor.manifest("missing-repository", sha, sha)) catch {
    DiffFailure(reason) => assert_true(reason.contains("queue wait exceeded"))
    err => raise err
  } noraise {
    _ => fail("manifest did not time out in queue")
  }
  assert_eq(executor.waiting, 0)
  assert_eq(executor.completed, 0)
  assert_eq(executor.cache.length(), 0)
  executor.slots.release()
}

///|
async test "manifest cache is rechecked after admission and shared across pagination file and anchors" {
  @test_support.with_git_test_repo((root, _) => {
    let dir = "\{root}/alice/demo.git"
    let (base, head) = @test_support.structured_diff_fixture(dir)
    let executor = DiffExecutor::new(
      worker="_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe",
    )
    executor.slots.acquire()
    @async.with_task_group(group => {
      let first = group.spawn(() => executor.manifest(dir, base, head))
      let second = group.spawn(() => executor.manifest(dir, base, head, page=2))
      @async.sleep(20)
      assert_eq(executor.waiting, 2)
      executor.slots.release()
      assert_eq(first.wait().files.length(), 100)
      assert_true(second.wait().files.length() > 0)
    })
    assert_eq(executor.completed, 1)
    let second = executor.manifest(dir, base, head, page=2)
    for
      (old_path, new_path, side) in [
        ("", "z-add.txt", "new"),
        ("z-delete.txt", "", "old"),
        ("z-old.txt", "z-new.txt", "old"),
        ("z-old.txt", "z-new.txt", "new"),
      ] {
      let anchor : DiffAnchor = {
        commit_sha: "",
        base_sha: base,
        head_sha: head,
        old_path,
        new_path,
        side,
        start_line: 1L,
        end_line: 1L,
        context: "saved",
      }
      let (manifest, id) = executor.locate_anchor(dir, anchor).unwrap()
      assert_eq(manifest.page, 2)
      assert_true(second.files.iter().any(f => f.id == id))
    }
    assert_eq(executor.completed, 1)
    let first = executor.manifest(dir, base, head)
    let bad = first.files.filter(f => f.path_error is Some(_))
    assert_eq(bad.length(), 3)
    assert_true(bad.iter().any(f => f.status.has_prefix("R")))
    let ids : Map[String, Bool] = Map([])
    for file in first.files {
      ids[file.id] = true
    }
    assert_eq(ids.length(), first.files.length())
    let escaped = first.files
      .iter()
      .find_first(f => f.new_path == "\"bad-\\xff\"" && f.path_error is None)
      .unwrap()
    assert_true(
      bad.iter().any(f => f.new_path == escaped.new_path && f.id != escaped.id),
    )
    // Invalid names return before admission, blob reads or a worker launch.
    executor.slots.acquire()
    for file in bad {
      let result = executor.file(
        dir,
        first,
        file.id,
        @diff_protocol.Options::new(),
      )
      assert_true(result.document is None)
      assert_eq(result.error, file.path_error)
    }
    executor.slots.release()
    assert_eq(executor.completed, 1)
    let good = first.files
      .iter()
      .find_first(f => f.new_path == "a-100.txt")
      .unwrap()
    let document = executor.file(
      dir,
      first,
      good.id,
      @diff_protocol.Options::new(),
    )
    assert_true(document.document is Some(_))
    ignore(
      executor.structured(
        dir,
        base,
        head,
        @diff_protocol.Options::new(),
        file_id=good.id,
      ),
    )
    assert_eq(executor.completed, 2)
    assert_eq(executor.cache.length(), 2)
  })
}

///|
async test "manifest parsing and sorting remain cancellable within the execution deadline" {
  let a = "a".repeat(40)
  let raw = @utf8.encode(
    ":100644 100644 \{a} \{a} M\u{0000}x.mbt\u{0000}".repeat(20000),
  )
  let executor = DiffExecutor::new(deadline_ms=1)
  try
    ignore(
      executor.compute_cached("large", "manifest", () => {
        (Manifest(parse_diff_files(raw)), raw.length())
      }),
    )
  catch {
    DiffFailure(reason) => assert_true(reason.contains("manifest timed out"))
    err => raise err
  } noraise {
    _ => fail("manifest parsing blocked the deadline")
  }
  assert_true(executor.slots.try_acquire())
  executor.slots.release()
  assert_eq(executor.cache.length(), 0)
  let files = parse_diff_files(
    @utf8.encode(":100644 100644 \{a} \{a} M\u{0000}x.mbt\u{0000}"),
  )
  let unsorted = Array::make(20000, files[0])
  try
    ignore(
      executor.compute_cached("sort", "manifest", () => {
        (Manifest(sort_diff_files(unsorted)), 1)
      }),
    )
  catch {
    DiffFailure(reason) => assert_true(reason.contains("manifest timed out"))
    err => raise err
  } noraise {
    _ => fail("manifest sorting blocked the deadline")
  }
  assert_eq(executor.cache.length(), 0)
  assert_true(executor.slots.try_acquire())
  executor.slots.release()
}

///|
test "typed cache shares byte budget and oversized results leave retained entries intact" {
  let executor = DiffExecutor::new()
  executor.cache_result(
    "manifest:a",
    Manifest([]),
    @diff_protocol.cache_limit - 2,
  )
  executor.cache_result("file:a", Document("{}"), 2)
  assert_eq(executor.cache_bytes, @diff_protocol.cache_limit)
  executor.cache_result(
    "manifest:large",
    Manifest([]),
    @diff_protocol.cache_limit + 1,
  )
  assert_eq(executor.cache.length(), 2)
  assert_eq(executor.cache_bytes, @diff_protocol.cache_limit)
  executor.cache_result("manifest:b", Manifest([]), 3)
  assert_eq(executor.cache.length(), 2)
  assert_eq(executor.cache_bytes, 5)
  assert_true(executor.cache[0].0 == "file:a")
}

///|
async test "oversized completed results are returned without caching and simultaneous writes replace an entry" {
  let executor = DiffExecutor::new()
  let result = executor.compute_cached("huge", "manifest", () => {
    (Manifest([]), @diff_protocol.cache_limit + 1)
  })
  assert_true(result is Manifest([]))
  assert_eq(executor.cache.length(), 0)
  assert_eq(executor.completed, 1)
  executor.cache_result("same", Document("a"), 1)
  executor.cache_result("same", Document("bb"), 2)
  assert_eq(executor.cache.length(), 1)
  assert_eq(executor.cache_bytes, 2)
}

///|
async test "valid path identities retain the existing algorithm and either invalid rename side is isolated" {
  let sha = "a".repeat(40)
  let meta = @utf8.encode(":100644 100644 \{sha} \{sha} R100\u{0000}")
  let bytes = meta.to_array()
  bytes.append(b"old-\xff\x00valid-new\x00".to_array())
  bytes.append(meta.to_array())
  bytes.append(b"valid-old\x00new-\xfe\x00".to_array())
  let files = parse_diff_files(Bytes::from_array(bytes))
  assert_eq(files.length(), 2)
  assert_true(files.iter().all(f => f.path_error is Some(_)))
  assert_true(files[0].id != files[1].id)
  let normal = parse_diff_files(
      @utf8.encode(":100644 100644 \{sha} \{sha} M\u{0000}normal.mbt\u{0000}"),
    )[0]
  assert_eq(
    normal.id,
    diff_identity(["normal.mbt", "normal.mbt", "100644", "100644", sha, sha]),
  )
}

///|
async test "chunked manifest merge preserves interface priority and lexical pagination order" {
  let sha = "a".repeat(40)
  let raw = StringBuilder()
  for i in 0..<1025 {
    raw.write_string(
      ":100644 100644 \{sha} \{sha} M\u{0000}file-\{2024 - i}.mbt\u{0000}",
    )
  }
  raw.write_string(
    ":100644 100644 \{sha} \{sha} M\u{0000}pkg.generated.mbti\u{0000}",
  )
  let files = parse_diff_files(@utf8.encode(raw.to_string()))
  assert_eq(files.length(), 1026)
  assert_eq(files[0].new_path, "pkg.generated.mbti")
  for i in 0..<1025 {
    assert_eq(files[i + 1].new_path, "file-\{1000 + i}.mbt")
  }
}
