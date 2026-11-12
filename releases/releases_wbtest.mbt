///|
async test "draft assets publish immutable versions preserve bytes and reclaim deleted uploads" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let access = access(repo, Some(actor))
    let now = Ref(1000L)
    let service = Service::new(pool, root, clock=() => now.val)
    let sha = @gitops.branch_sha(repo.git_dir(root), "master")
    let release = service.create(access, "v1.0.0", sha, "Release", "notes")
    assert_true(release.draft)
    let sent = Ref(false)
    let asset = service.upload(
      access,
      release.id,
      "app.zip",
      "Installer",
      "application/zip",
      () => {
        if sent.val {
          None
        } else {
          sent.val = true
          Some(Bytes::make(9 * 1024 * 1024, b'C'))
        }
      },
    )
    assert_eq(asset.size, 9437184L)
    assert_eq(service.get(access, release.id).assets.length(), 1)
    let published = service.publish(access, release.id)
    assert_true(!published.draft)
    assert_eq(service.latest(access).id, release.id)
    assert_eq(
      @gitops.merge_git(repo.git_dir(root), ["rev-parse", "refs/tags/v1.0.0"])
      .trim()
      .to_owned(),
      sha,
    )
    let read : Array[Byte] = []
    service.download(access, asset.id, (_, reader, recheck) => {
      while reader.read() is Some(bytes) {
        recheck()
        read.push_iter(bytes.iter())
      }
    })
    assert_eq(read.length(), 9437184)
    try service.delete_asset(access, asset.id) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("published asset was deleted")
    }
    try ignore(service.edit(access, release.id, title="changed")) catch {
      Conflict(_) => ()
      err => raise err
    } noraise {
      _ => fail("published release changed")
    }
    now.val = 2000000000000L
    service.cleanup()
    assert_eq(service.get(access, release.id).assets.length(), 1)
    let temporary = service.create(access, "v2.0.0", sha, "Draft", "notes")
    let sent2 = Ref(false)
    let disposable = service.upload(
      access,
      temporary.id,
      "old.zip",
      "",
      "application/zip",
      () => {
        if sent2.val {
          None
        } else {
          sent2.val = true
          Some(b"temporary")
        }
      },
    )
    service.delete_asset(access, disposable.id)
    now.val += 600001L
    service.cleanup()
    now.val += 600001L
    service.cleanup()
    assert_true(service.get(access, temporary.id).assets.is_empty())
    assert_true(
      pool.with_client(c => {
        c.query_all("SELECT * FROM release_blob_garbage").is_empty()
      }),
    )
  })
}

///|
async test "release upload rechecks rights and concurrent target publication" {
  @test_support.with_repository_test_data((pool, root) => {
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let allowed = Ref(true)
    let scoped = access(repo, Some(actor), recheck=_ => {
      guard allowed.val else { raise @domain.Forbidden(message="revoked") }
    })
    let service = Service::new(pool, root)
    let sha = @gitops.branch_sha(repo.git_dir(root), "master")
    let release = service.create(scoped, "v1.0.1", sha, "Draft", "")
    try
      ignore(
        service.upload(scoped, release.id, "file.zip", "", "application/zip", () => {
          allowed.val = false
          Some(b"secret")
        }),
      )
    catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("revoked upload finalized")
    }
    allowed.val = true
    assert_true(service.get(scoped, release.id).assets.is_empty())
    let read_only = access(repo, Some(actor), recheck=write => {
      guard !write else { raise @domain.Forbidden(message="read only") }
    })
    try ignore(service.get(read_only, release.id)) catch {
      @domain.NotFound(_) => ()
      err => raise err
    } noraise {
      _ => fail("read token saw draft")
    }
    try ignore(service.create(read_only, "v2", sha, "", "")) catch {
      @domain.Forbidden(_) => ()
      err => raise err
    } noraise {
      _ => fail("read token created release")
    }
  })
}

///|
async test "configured filesystem release namespaces are excluded from legacy CI orphan scanning" {
  @test_support.with_repository_test_data((pool, root) => {
    let shared = root + "/.pipeline-artifacts"
    let config = @storage.Config::parse({
      "artifacts": "shared",
      "caches": "shared",
      "backends": { "shared": { "type": "fs", "root": shared } },
    })
    let actor = @identity.active_user_by_name(pool, "alice")
    let repo : @domain.RepoId = { owner: "alice", name: "demo", }
    let service = Service::new(pool, root, storage=config)
    let r = service.create(
      access(repo, Some(actor)),
      "v6.0.0",
      @gitops.branch_sha(repo.git_dir(root), "master"),
      "Release",
      "",
    )
    let sent = Ref(false)
    let a = service.upload(
      access(repo, Some(actor)),
      r.id,
      "file.zip",
      "",
      "application/zip",
      () => {
        if sent.val {
          None
        } else {
          sent.val = true
          Some(b"retained release")
        }
      },
    )
    let visited = Ref(0)
    config
    .resolve(config.artifacts, legacy_root=shared)
    .visit_filesystem_namespaces(_ => {
      visited.val += 1
      true
    })
    assert_eq(visited.val, 0)
    assert_true(a.storage_key.has_prefix("release_"))
  })
}
