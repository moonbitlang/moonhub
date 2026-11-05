///|
fn diff_test_request() -> @diff_protocol.Request {
  {
    protocol: @diff_protocol.protocol_version,
    old_path: "x.mbt",
    new_path: "x.mbt",
    old_source: Some("fn a() { 1 }\n"),
    new_source: Some("fn a() { 2 }\n"),
    options: @diff_protocol.Options::new(),
  }
}

///|
async test "worker protocol roundtrip caches completed results with repository identity" {
  let executor = DiffExecutor::new(
    worker="_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe",
  )
  executor.verify()
  let doc = executor.execute("repo-a", () => diff_test_request())
  assert_eq(doc.status, "changed")
  let _ = executor.execute("repo-a", () => fail("cache did not hit"))
  assert_eq(executor.cache_hits, 1)
  let _ = executor.execute("repo-b", () => diff_test_request())
  assert_eq(executor.completed, 2)
}

///|
async test "raw manifest and bounded worker retain rename modes and immutable blobs" {
  @test_support.with_repository_test_data((_pool, root) => {
    let dir = "\{root}/alice/demo.git"
    let base = branch_sha(dir, "master")
    let head = @test_support.merge_test_commit(dir, "feature", base, "two\n")
    let executor = DiffExecutor::new(
      worker="_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe",
    )
    let manifest = executor.manifest(dir, base, head)
    assert_true(manifest.files.length() > 0)
    let file = manifest.files
      .iter()
      .find_first(f => f.new_path == "README.md")
      .unwrap()
    let result = executor.file(
      dir,
      manifest,
      file.id,
      @diff_protocol.Options::new(),
    )
    assert_true(result.document is Some({ options: { mode: "line", .. }, .. }))
    assert_true(result.error is None)
    let moved = @test_support.merge_test_commit(dir, "feature", head, "three\n")
    let still = executor.manifest(dir, base, head)
    assert_eq(still.comparison_id, manifest.comparison_id)
    assert_true(moved != head)
    try
      ignore(executor.file(dir, manifest, base, @diff_protocol.Options::new()))
    catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("accepted object ID as file ID")
    }
  })
}

///|
async test "noncooperative CPU worker does not block event loop and is reaped on timeout and cancellation" {
  if @async.platform is Windows {
    return
  }
  @test_support.with_git_test_repo((root, _) => {
    let script = "\{root}/cpu-worker"
    let pid_file = "\{root}/pid"
    @fs.write_file(
      script,
      "#!/bin/sh\necho $$ > '\{pid_file}'\nwhile :; do :; done\n",
    )
    @fs.chmod(script, 0o700)
    for phase in ["file", "manifest"] {
      let executor = DiffExecutor::new(worker=script, deadline_ms=1000)
      let run = async fn(key) {
        if phase == "file" {
          ignore(executor.execute(key, () => diff_test_request()))
        } else {
          ignore(
            executor.compute_cached(key, "manifest", () => {
              let raw = bounded_process(script, [], "", 16777216)
              Manifest(parse_diff_files(raw))
            }),
          )
        }
      }
      @async.with_task_group(group => {
        let task = group.spawn(() => {
          try run("timeout") catch {
            DiffFailure(message) => assert_true(message.contains("timed out"))
            err => raise err
          } noraise {
            _ => fail("CPU worker did not time out")
          }
        })
        @async.sleep(60)
        assert_true(task.try_wait() is None)
        // This Git process must run while the worker is still consuming CPU.
        assert_eq(
          diff_text(bounded_process("git", ["--version"], "", 1024)).has_prefix(
            "git version",
          ),
          true,
        )
        assert_true(task.try_wait() is None)
        task.wait()
        let pid = @fs.read_file(pid_file).text().trim().to_owned()
        let (code, _, _) = @process.collect_output("kill", ["-0", pid])
        assert_true(code != 0)
        let task = group.spawn(() => run("cancel"))
        @async.sleep(60)
        task.cancel()
        ignore(task.wait()) catch {
          @async.WaitedTaskAlreadyCancelled => ()
          err => raise err
        }
      })
      assert_eq(executor.waiting, 0)
      assert_true(executor.slots.try_acquire())
      executor.slots.release()
      let pid = @fs.read_file(pid_file).text().trim().to_owned()
      let (code, _, _) = @process.collect_output("kill", ["-0", pid])
      assert_true(code != 0)
      assert_eq(executor.cache.length(), 0)
    }
  })
}

///|
async test "worker stderr is drained and output limits terminate subprocess" {
  if @async.platform is Windows {
    return
  }
  assert_eq(
    bounded_process(
      "sh",
      ["-c", "head -c 131072 /dev/zero >&2; printf ok"],
      "",
      16,
    ),
    b"ok",
  )
  try
    ignore(
      bounded_process(
        "sh",
        ["-c", "while :; do printf 1234567890; done"],
        "",
        32,
      ),
    )
  catch {
    DiffFailure(message) => assert_eq(message, "output limit exceeded")
    err => raise err
  } noraise {
    _ => fail("accepted excessive output")
  }
  try ignore(bounded_process("sh", ["-c", "exit 2"], "", 32)) catch {
    DiffFailure(_) => ()
    err => raise err
  } noraise {
    _ => fail("accepted failed worker")
  }
}

///|
async test "queue has a bounded wait and cancellation returns all waiting permits" {
  let executor = DiffExecutor::new()
  executor.slots.acquire()
  @async.with_task_group(group => {
    let tasks = []
    for i in 0..<16 {
      tasks.push(
        group.spawn(() => {
          executor.execute("queued-\{i}", () => {
            fail("loaded source before acquiring a slot")
          })
        }),
      )
    }
    @async.sleep(20)
    assert_eq(executor.waiting, 16)
    try
      ignore(executor.execute("overflow", () => fail("loaded overflow source")))
    catch {
      DiffFailure(message) => assert_true(message.contains("queue is full"))
      err => raise err
    } noraise {
      _ => fail("unbounded queue")
    }
    for task in tasks {
      task.cancel()
    }
    for task in tasks {
      ignore(task.wait()) catch {
        @async.WaitedTaskAlreadyCancelled => ()
        err => raise err
      }
    }
  })
  assert_eq(executor.waiting, 0)
  try
    ignore(executor.execute("deadline", () => fail("loaded expired source")))
  catch {
    DiffFailure(message) => assert_true(message.contains("queue wait exceeded"))
    err => raise err
  } noraise {
    _ => fail("queue did not time out")
  }
  assert_eq(executor.waiting, 0)
  executor.slots.release()
  assert_true(executor.slots.try_acquire())
  executor.slots.release()
}

///|
async test "NUL raw records preserve unusual paths renames modes and generated interface priority" {
  let a = "a".repeat(40)
  let b = "b".repeat(40)
  let files = parse_diff_files(
    @utf8.encode(
      ":100644 100755 \{a} \{b} M\u{0000}z\t\n.mbt\u{0000}:100644 100644 \{a} \{a} R100\u{0000}old name.mbt\u{0000}:new\nname.mbt\u{0000}:000000 100644 \{"0".repeat(40)} \{b} A\u{0000}pkg.generated.mbti\u{0000}",
    ),
  )
  assert_eq(files.length(), 3)
  assert_eq(files[0].new_path, "pkg.generated.mbti")
  let rename = files.iter().find_first(f => f.status == "R100").unwrap()
  assert_eq(rename.old_path, "old name.mbt")
  assert_eq(rename.new_path, ":new\nname.mbt")
  let mode = files.iter().find_first(f => f.new_mode == "100755").unwrap()
  assert_eq(mode.old_mode, "100644")
  assert_eq(mode.new_path, "z\t\n.mbt")
}

///|
async test "root comparison file failures are isolated and manifest pagination is stable" {
  @test_support.with_git_test_repo((root, _) => {
    let dir = "\{root}/alice/demo.git"
    let binary = merge_git(
        dir,
        ["hash-object", "-w", "--stdin"],
        input="\u{0000}binary",
      )
      .trim()
      .to_owned()
    @fs.write_file("\{root}/invalid-utf8", b"\xff")
    let invalid = run_git(dir, ["hash-object", "-w", "\{root}/invalid-utf8"])
      .trim()
      .to_owned()
    let text = merge_git(dir, ["hash-object", "-w", "--stdin"], input="text\n")
      .trim()
      .to_owned()
    let tree_input = StringBuilder()
    tree_input.write_string(
      "100644 blob \{binary}\tbinary\n100644 blob \{invalid}\tinvalid\n",
    )
    for i in 0..<101 {
      tree_input.write_string("100644 blob \{text}\tfile-\{i}\n")
    }
    let tree = merge_git(dir, ["mktree"], input=tree_input.to_string())
      .trim()
      .to_owned()
    let commit = merge_git(dir, ["commit-tree", tree, "-m", "Root"])
      .trim()
      .to_owned()
    let (empty, head) = commit_comparison(dir, commit)
    assert_eq(head, commit)
    let executor = DiffExecutor::new(
      worker="_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe",
    )
    let first = executor.manifest(dir, empty, head)
    let second = executor.manifest(dir, empty, head, page=2)
    assert_eq(first.files.length(), 100)
    assert_true(first.has_more)
    assert_eq(second.files.length(), 3)
    assert_true(!second.has_more)
    assert_eq(first.comparison_id, second.comparison_id)
    let binary = first.files
      .iter()
      .find_first(f => f.new_path == "binary")
      .unwrap()
    let result = executor.file(
      dir,
      first,
      binary.id,
      @diff_protocol.Options::new(),
    )
    assert_true(result.error == Some("binary file"))
    let invalid = second.files
      .iter()
      .find_first(f => f.new_path == "invalid")
      .unwrap()
    let result = executor.file(
      dir,
      second,
      invalid.id,
      @diff_protocol.Options::new(),
    )
    assert_true(result.error == Some("non-UTF-8 content"))
    let text = second.files
      .iter()
      .find_first(f => f.new_path != "invalid")
      .unwrap()
    let result = executor.file(
      dir,
      second,
      text.id,
      @diff_protocol.Options::new(),
    )
    assert_true(result.document is Some(_))
  })
}

///|
async test "failed worker calculations are never cached" {
  let executor = DiffExecutor::new(
    worker="_build/native/debug/build/cmd/moonhub-diff-worker/moonhub-diff-worker.exe",
  )
  let request = diff_test_request()
  try
    ignore(
      executor.execute("bad", () => { ..request, protocol: "unsupported", }),
    )
  catch {
    DiffFailure(message) => assert_eq(message, "unsupported diff protocol")
    err => raise err
  } noraise {
    _ => fail("accepted incompatible request")
  }
  assert_true(!executor.cache.contains("file:bad"))
  assert_eq(executor.failures, 1)
}
