///|
async fn storage_test_read(store : Store, key : String, size : Int64) -> Bytes {
  let bytes : Array[Byte] = []
  store.with_reader(key, size, reader => {
    while reader.read() is Some(chunk) {
      bytes.append(chunk.to_array())
    }
  })
  Bytes::from_array(bytes)
}

///|
async fn storage_test_contract(store : Store) -> Unit {
  let hash = bytes => @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
  store.put("sample/first", b"abc")
  store.put("sample/second", b"def")
  let parts : Array[Part] = [
    { key: "sample/second", size: 3L, digest: hash(b"def"), },
    { key: "sample/first", size: 3L, digest: hash(b"abc"), },
  ]
  let info = store.compose("sample/archive-one", parts)
  assert_eq(info.size, 6L)
  assert_eq(info.digest, "sha256:" + hash(b"defabc"))
  assert_eq(storage_test_read(store, "sample/archive-one", 6L), b"defabc")
  try ignore(store.compose("sample/archive-one", parts)) catch {
    _ => ()
  } noraise {
    _ => fail("overwrote an immutable archive")
  }
  assert_eq(storage_test_read(store, "sample/archive-one", 6L), b"defabc")
  let called = Ref(false)
  try
    store.with_reader("sample/archive-one", 7L, _ => called.val = true)
  catch {
    _ => ()
  } noraise {
    _ => fail("opened an archive with the wrong expected size")
  }
  assert_false(called.val)
  try
    store.compose("sample/corrupt", [
      { key: "sample/first", size: 3L, digest: "0".repeat(64), },
    ])
  catch {
    _ => ()
  } noraise {
    _ => fail("accepted corrupted staged data")
  }
  store.remove("sample/first")
  store.remove("sample/first")
  store.remove_namespace("sample")
  store.remove_namespace("sample")
  try ignore(storage_test_read(store, "sample/archive-one", 6L)) catch {
    _ => ()
  } noraise {
    _ => fail("deleted archive remains readable")
  }
}

///|
async test "filesystem stores ordered immutable streams and rejects corruption before publication" {
  let root = @fs.tmpdir(prefix="moonhub-storage-")
  defer @fs.rmdir(root, recursive=true)
  storage_test_contract(filesystem(root))
  for
    key in [
      "../escape", "/absolute", "sample/../escape", "sample/", "sample/a?x", "a/b/c",
    ] {
    try filesystem(root).put(key, b"x") catch {
      InvalidKey => ()
      err => raise err
    } noraise {
      _ => fail("invalid key accepted: " + key)
    }
  }
}

///|
async test "filesystem backend rejects symlink directories and files" {
  let root = @fs.tmpdir(prefix="moonhub-storage-links-")
  defer @fs.rmdir(root, recursive=true)
  @fs.mkdir(root + "/outside")
  @fs.symlink(target=root + "/outside", root + "/link")
  try filesystem(root).put("link/file", b"x") catch {
    IntegrityFailure => ()
    err => raise err
  } noraise {
    _ => fail("followed symlink namespace")
  }
  @fs.write_file(root + "/outside/data", b"x")
  @fs.symlink(target=root + "/outside/data", root + "/outside/link")
  try ignore(storage_test_read(filesystem(root), "outside/link", 1L)) catch {
    IntegrityFailure => ()
    err => raise err
  } noraise {
    _ => fail("followed symlink object")
  }
}

///|
test "storage configuration resolves persisted destinations independently of current defaults" {
  let config = Config::parse({
    "artifacts": "local",
    "caches": "remote",
    "backends": {
      "local": { "type": "fs", "root": "/var/lib/moonhub/blobs" },
      "remote": {
        "type": "s3",
        "bucket": "moonhub-blobs",
        "region": "us-west-2",
        "prefix": "ci/cache",
      },
    },
  })
  assert_true(config.artifacts.contains("/var/lib/moonhub/blobs"))
  assert_true(config.caches.contains("moonhub-blobs"))
  assert_eq(
    config.resolve(config.caches, legacy_root="/old").location(),
    config.caches,
  )
  assert_eq(
    config.resolve("legacy-fs", legacy_root="/old").location(),
    filesystem("/old").location(),
  )
  for
    descriptor in [
      ({ "type": "fs", "root": "relative" } : Json),
      {
        "type": "s3",
        "bucket": "moonhub-blobs",
        "region": "us-west-2",
        "prefix": "../cache",
      },
      {
        "type": "s3",
        "bucket": "moonhub-blobs",
        "region": "us-west-2",
        "prefix": "cache",
        "secret_key": "forbidden",
      },
      {
        "type": "s3",
        "bucket": "moonhub-blobs",
        "region": "us-west-2",
        "prefix": "cache",
        "endpoint": "http://example.com",
      },
    ] {
    try
      ignore(
        Config::parse({
          "artifacts": "x",
          "caches": "x",
          "backends": { "x": descriptor },
        }),
      )
    catch {
      InvalidConfiguration => ()
      err => raise err
    } noraise {
      _ => fail("invalid storage configuration accepted")
    }
  }
}

///|
async test "S3 live storage preserves the filesystem contract without local staging" {
  guard @env.get_env_var("MOONHUB_TEST_S3_CONFIG") is Some(value) else {
    return
  }
  let config = Config::parse(@json.parse(value))
  storage_test_contract(config.resolve(config.artifacts, legacy_root="unused"))
}

///|
async test "S3 live large archive streams beyond the old artifact limit without local staging" {
  guard @env.get_env_var("MOONHUB_TEST_S3_CONFIG") is Some(value) else {
    return
  }
  let config = Config::parse(@json.parse(value))
  let store = config.resolve(config.artifacts, legacy_root="unused")
  let bytes = @utf8.encode("a".repeat(8388608))
  let digest = @crypto.bytes_to_hex_string(@crypto.sha256(bytes))
  store.put("large/block", bytes)
  let parts : Array[Part] = []
  let expected = @crypto.SHA256::new()
  for _ in 0..<75 {
    parts.push({ key: "large/block", size: bytes.length().to_int64(), digest, })
    expected.update(bytes)
  }
  let info = store.compose("large/archive", parts)
  assert_eq(info.size, 629145600L)
  assert_eq(
    info.digest,
    "sha256:" + @crypto.bytes_to_hex_string(expected.finalize()),
  )
  let received = @crypto.SHA256::new()
  let mut size = 0L
  store.with_reader("large/archive", info.size, reader => {
    while reader.read() is Some(chunk) {
      size += chunk.length().to_int64()
      received.update(chunk)
    }
  })
  assert_eq(size, info.size)
  assert_eq(
    "sha256:" + @crypto.bytes_to_hex_string(received.finalize()),
    info.digest,
  )
  store.remove_namespace("large")
}

///|
async test "namespace cleanup refuses nested and dangling symlinks and retries missing paths" {
  let root = @fs.tmpdir(prefix="moonhub-storage-cleanup-")
  defer @fs.rmdir(root, recursive=true)
  let store = filesystem(root + "/blobs")
  @fs.mkdir(root + "/outside")
  @fs.write_file(root + "/outside/keep", b"keep")
  store.put("sample/data", b"data")
  @fs.mkdir(root + "/blobs/sample/nested")
  @fs.symlink(target=root + "/outside", root + "/blobs/sample/nested/link")
  try store.remove_namespace("sample") catch {
    IntegrityFailure => ()
    err => raise err
  } noraise {
    _ => fail("cleanup accepted a nested symlink")
  }
  assert_eq(@fs.read_file(root + "/outside/keep").text(), "keep")
  @fs.remove(root + "/blobs/sample/nested/link")
  @fs.symlink(target=root + "/missing", root + "/blobs/dangling")
  try store.remove_namespace("dangling") catch {
    IntegrityFailure => ()
    err => raise err
  } noraise {
    _ => fail("cleanup accepted a dangling symlink")
  }
  @fs.remove(root + "/blobs/dangling")
  store.remove_namespace("sample")
  store.remove_namespace("sample")
  assert_false(@fs.exists(root + "/blobs/sample"))
}
